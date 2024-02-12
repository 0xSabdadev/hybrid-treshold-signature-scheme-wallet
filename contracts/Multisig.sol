// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/utils/cryptography/ECDSA.sol";
import "./MultiSigFactory.sol";

contract MultiSigTA {
    using ECDSA for bytes32; // Using ECDSA library for bytes32 type

    address[] public walletOwners;
    address multisigIntance;
    address mainOwner;
    uint public limit;
    bool private locked;
    uint public depositId = 0;
    uint public withdrawalId = 0;
    uint public transferId = 0;
    string[] public tokenList;

    constructor() {
        mainOwner = msg.sender;
        walletOwners.push(mainOwner);
        limit = walletOwners.length - 1;
        tokenList.push("ETH");
        locked = false;
    }

    mapping(address => mapping(string => uint)) public balance;
    mapping(address => mapping(uint => bool)) public approvals;
    mapping(address => bool) public withdrawing;
    mapping(address => bool) public withdrawalInProcess;
    mapping(string => Token) public tokenMapping;
    mapping(address => uint) public balancesToWithdraw;
    mapping(address => string) public tickerToWithdraw;

    struct Token {
        string ticker;
        address tokenAddress;
    }

    struct Transfer {
        string ticker;
        address sender;
        address payable receiver;
        uint amount;
        uint id;
        uint approvals;
        uint timeOfTransaction;
        bool executed;
    }

    Transfer[] public transferRequests;

    event walletOwnerAdded(address addedBy, address ownerAdded, uint timeOfTransaction);
    event walletOwnerRemoved(address removedBy, address ownerRemoved, uint timeOfTransaction);
    event fundsDeposited(string ticker, address sender, uint amount, uint depositId, uint timeOfTransaction);
    event fundsWithdrawed(string ticker, address sender, uint amount, uint withdrawalId, uint timeOfTransaction);
    event transferCreated(string ticker, address sender, address receiver, uint amount, uint id, uint approvals, uint timeOfTransaction);
    event transferCancelled(string ticker, address sender, address receiver, uint amount, uint id, uint approvals, uint timeOfTransaction);
    event transferApproved(string ticker, address sender, address receiver, uint amount, uint id, uint approvals, uint timeOfTransaction);
    event fundsTransfered(string ticker, address sender, address receiver, uint amount, uint id, uint approvals, uint timeOfTransaction);
    event tokenAdded(address addedBy, string ticker, address tokenAddress, uint timeOfTransaction);
    mapping(uint => mapping(address => bool)) approvedByTransfer; // Mapping untuk menyimpan data approvedBy

    modifier onlyOwners() {
        bool ownerFound = false; // Mengubah nama variabel agar tidak bertabrakan dengan fungsi lokal
        for (uint i = 0; i < walletOwners.length; i++) {
            if (walletOwners[i] == msg.sender) {
                ownerFound = true;
                break;
            }
        }
        require(ownerFound == true, "Only wallet owners can call this function");
        _;
    }


    modifier tokenExists(string memory ticker) {
        if (keccak256(bytes(ticker)) != keccak256(bytes("ETH"))) {
            require(tokenMapping[ticker].tokenAddress != address(0), "Token is not available");
        }
        _;
    }

    modifier mutexApplied() {
        require(!locked, "Reentrancy guard: locked");
        locked = true;
        _;
        locked = false;
    }

    modifier hasNotApproved(uint id) {
        require(!approvals[msg.sender][id], "Signature has already been collected");
        _;
    }

    

    function addToken(string memory ticker, address _tokenAddress) public onlyOwners {
        for (uint i = 0; i < tokenList.length; i++) {
            require(keccak256(bytes(tokenList[i])) != keccak256(bytes(ticker)), "Cannot add duplicate token");
        }
        require(keccak256(bytes(ERC20(_tokenAddress).symbol())) == keccak256(bytes(ticker)), "Token is not available in ERC20");
        tokenMapping[ticker] = Token(ticker, _tokenAddress);
        tokenList.push(ticker);
        emit tokenAdded(msg.sender, ticker, _tokenAddress, block.timestamp);
    }

    function setMultisigContractAdress(address walletAddress) private {
        multisigIntance = walletAddress;
    }

    function callAddOwner(address owner, address multiSigContractInstance) private {
        MultiSigFactory factory = MultiSigFactory(multisigIntance);
        factory.addNewWalletInstance(owner, multiSigContractInstance);
    }
    
    function callRemoveOwner(address owner, address multiSigContractInstance) private {
        MultiSigFactory factory = MultiSigFactory(multisigIntance);
        factory.removeNewWalletInstance(owner, multiSigContractInstance);
    }

    function addWalletOwner(address owner, address walletAddress, address _address) public onlyOwners {
        for (uint i = 0; i < walletOwners.length; i++) {
            require(walletOwners[i] != owner, "Cannot add duplicate owner");
        }
        require(limit < 2, "Limit reached");
        walletOwners.push(owner);
        limit = walletOwners.length - 1;
        emit walletOwnerAdded(msg.sender, owner, block.timestamp);
        setMultisigContractAdress(walletAddress);
        callAddOwner(owner, _address);
    }

    function removeWalletOwner(address owner, address walletAddress, address _address) public onlyOwners {
        bool hasBeenFound = false;
        uint ownerIndex;
        for (uint i = 0; i < walletOwners.length; i++) {
            if (walletOwners[i] == owner) {
                hasBeenFound = true;
                ownerIndex = i;
                break;
            }
        }
        require(hasBeenFound == true, "Wallet owner not detected");
        walletOwners[ownerIndex] = walletOwners[walletOwners.length - 1];
        walletOwners.pop();
        limit = walletOwners.length - 1;
        emit walletOwnerRemoved(msg.sender, owner, block.timestamp);
        setMultisigContractAdress(walletAddress);
        callRemoveOwner(owner, _address);
    }

    function deposit(string memory ticker, uint amount) public payable onlyOwners tokenExists(ticker) {
        require(balance[msg.sender][ticker] >= 0, "Cannot deposit 0 value");
        if (keccak256(bytes(ticker)) == keccak256(bytes("ETH"))) {
            balance[msg.sender]["ETH"] += msg.value;
        } else {
            require(tokenMapping[ticker].tokenAddress != address(0), "Token is not available");
            bool transferSuccess = IERC20(tokenMapping[ticker].tokenAddress).transferFrom(msg.sender, address(this), amount);
            require(transferSuccess, "ERC20 transfer failed");
            balance[msg.sender][ticker] += amount;
        }
        emit fundsDeposited(ticker, msg.sender, amount, depositId, block.timestamp);
        depositId++;
    }

    function withdraw(string memory ticker, uint _amount) public onlyOwners {
        require(_amount > 0, "Amount must be greater than 0");
        require(balance[msg.sender][ticker] >= _amount, "Insufficient balance");
        if (keccak256(bytes(ticker)) != keccak256(bytes("ETH"))) {
            require(tokenMapping[ticker].tokenAddress != address(0), "Token is not available");
        }
        bool transferSuccess = false;
        if (keccak256(bytes(ticker)) == keccak256(bytes("ETH"))) {
            (transferSuccess,) = payable(msg.sender).call{value: _amount}("");
        } else {
            require(tokenMapping[ticker].tokenAddress != address(0), "Token is not available");
            transferSuccess = IERC20(tokenMapping[ticker].tokenAddress).transfer(msg.sender, _amount);
        }
        require(transferSuccess, "ERC20 transfer failed");
        balance[msg.sender][ticker] -= _amount;
        emit fundsWithdrawed(ticker, msg.sender, _amount, withdrawalId, block.timestamp);
        withdrawalId++;
    }

    function createTransferRequest(string memory ticker, address payable receiver, uint amount, bytes memory signature) public onlyOwners tokenExists(ticker) {
        require(balance[msg.sender][ticker] >= amount, "Insufficient balance for transfer");
        require(walletOwners.length == 3, "TSS requires exactly 3 owners");
        require(receiver != address(0), "Invalid receiver address");
        for (uint i = 0; i < walletOwners.length; i++) {
            require(walletOwners[i] != receiver, "tidak bisa transfer funds pada wallet pribadi");
        }
        // Verify signature of the sender
        bytes32 messageHash = keccak256(abi.encodePacked(ticker, receiver, amount));

        // Concatenate signature and message hash for verification
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address signer = prefixedHash.recover(signature);
        require(isOwner(signer), "Invalid signature");

        // Mark the sender as approved
        approvedByTransfer[transferId][msg.sender] = true; // Update mapping approvedBy
        
        
        balance[msg.sender][ticker] -= amount;
        transferRequests.push(Transfer(ticker, msg.sender, receiver, amount, transferId, 1, block.timestamp, false));
        transferId++;

        // Emit event for transfer request
        emit transferCreated(ticker, msg.sender, receiver, amount, transferId, 1, block.timestamp);
    }

    function cancelTransferRequest( string memory ticker, uint id) public onlyOwners {
        // string memory ticker = transferRequests[id].ticker;
        bool hasBeenFound = false;
        uint transferIndex = 0;
        for (uint i = 0; i < transferRequests.length; i++) {
            if(transferRequests[i].id == id) {
                hasBeenFound = true;
                break;
            }
             transferIndex++;
        }
        
        require(transferRequests[transferIndex].sender == msg.sender, "hanya transfer creator yang dapat cancel");
        require(hasBeenFound, "transfer request tidak tersedia");
        
        balance[msg.sender][ticker] += transferRequests[transferIndex].amount;
        transferRequests[transferIndex] = transferRequests[transferRequests.length - 1];
        emit transferCancelled(ticker, msg.sender, transferRequests[transferIndex].receiver, transferRequests[transferIndex].amount, transferRequests[transferIndex].id, transferRequests[transferIndex].approvals, transferRequests[transferIndex].timeOfTransaction);
        transferRequests.pop();
    }

    function approveTransferRequest(string memory ticker,uint id, bytes memory signature) public onlyOwners {
        require(id < transferRequests.length, "Invalid transfer ID");
        require(!transferRequests[id].executed, "Transfer request already executed");

        // Verify signature of the sender
        bytes32 messageHash = keccak256(abi.encodePacked(id));
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address signer = prefixedHash.recover(signature);
        require(isOwner(signer), "Invalid signature");

        // Check if the sender has not approved before
        require(!approvedByTransfer[id][signer], "Duplicate signature");

        // Mark the sender as approved
        approvedByTransfer[id][signer] = true;
        transferRequests[id].approvals++;

        // Check if enough valid signatures were provided
        require(transferRequests[id].approvals >= limit, "Insufficient approvals");

        // Execute the transfer
        transferRequests[id].receiver.transfer(transferRequests[id].amount);
        transferRequests[id].executed = true;
        emit transferApproved(ticker, msg.sender, transferRequests[id].receiver, transferRequests[id].amount, id, transferRequests[id].approvals, block.timestamp);
        // emit transferApproved(ticker, msg.sender, transferRequests[transferIndex].receiver, transferRequests[transferIndex].amount, transferRequests[transferIndex].id, transferRequests[transferIndex].approvals, transferRequests[transferIndex].timeOfTransaction);
        if (transferRequests[id].approvals == limit) {
            transferFunds(ticker, id);
        }
    }

    function transferFunds(string memory ticker, uint id) private mutexApplied{
        bool transferSuccess = false;
        balance[transferRequests[id].receiver][ticker] += transferRequests[id].amount;
        if(keccak256(bytes(ticker)) == keccak256(bytes("ETH"))) {
            // transferRequests[id].receiver.transfer(transferRequests[id].amount);
            (transferSuccess,) = transferRequests[id].receiver.call{value: transferRequests[id].amount}("");
        }
        else {
            transferSuccess = IERC20(tokenMapping[ticker].tokenAddress).transfer(transferRequests[id].receiver, transferRequests[id].amount);
        }
        require(transferSuccess, "ERC20 transfer failed");
        emit fundsTransfered(ticker, msg.sender, transferRequests[id].receiver, transferRequests[id].amount, transferRequests[id].id, transferRequests[id].approvals, transferRequests[id].timeOfTransaction);
        transferRequests[id] = transferRequests[transferRequests.length - 1];
        transferRequests.pop();
    }


    function getApprovals(uint id) public onlyOwners view returns (bool) {
        return approvals[msg.sender][id];
    }

    function isOwner(address _address) private view returns (bool) {
        for (uint i = 0; i < walletOwners.length; i++) {
            if (walletOwners[i] == _address) {
                return true;
            }
        }
        return false;
    }

    function getTransferRequests() public onlyOwners view returns (Transfer[] memory) {
        return transferRequests;
    }

    function getBalance(string memory ticker) public view returns (uint) {
        return balance[msg.sender][ticker];
    }

    function getApprovalLimit() public onlyOwners view returns (uint) {
        return limit;
    }

    function getContractBalance() public view returns (uint) {
        return address(this).balance;
    }

    function getWalletOwners() public view onlyOwners returns (address[] memory) {
        return walletOwners;
    }

    function getTokenList() public view returns (string[] memory) {
        return tokenList;
    }
}
