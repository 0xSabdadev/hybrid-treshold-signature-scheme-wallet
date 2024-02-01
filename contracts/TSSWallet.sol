// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "./MultiSigFactory.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Arrays.sol";

contract MultiSigTA {
    using SafeMath for uint256;
    using Arrays for uint256[];

    address mainOwner;
    address multisigIntance;
    address[] walletowners;
    uint256 public threshold;
    uint depositId = 0;
    uint withdrawalId = 0;
    uint transferId = 0;
    string[] tokenList;
    bool private locked;

    constructor() {
        mainOwner = msg.sender;
        walletowners.push(mainOwner);
        threshold = 2; // Set your desired threshold here
        tokenList.push("ETH");
        locked = false;
    }

    mapping(address => mapping(string => uint256)) balance;
    mapping(address => bool) withdrawing;
    mapping(address => bool) public withdrawalInProcess;
    mapping(string => Token) tokenMapping;
    mapping(address => uint256) public balancesToWithdraw;
    mapping(address => string) public tickerToWithdraw;

    struct Token {
        string ticker;
        address tokenAddress;
    }

    struct Transfer {
    string ticker;
    address sender;
    address payable receiver;
    uint256 amount;
    uint256 id;
    uint256 approvals;
    uint256 timeOfTransaction;
    address[] approvers;
}
    Transfer[] transferRequests;

    event walletOwnerAdded(address addedBy, address ownerAdded, uint timeOfTransaction);
    event walletOwnerRemoved(address removedBy, address ownerRemoved, uint timeOfTransaction);
    event fundsDeposited(string ticker, address sender, uint256 amount, uint256 depositId, uint256 timeOfTransaction);
    event fundsWithdrawed(string ticker, address sender, uint256 amount, uint256 withdrawalId, uint256 timeOfTransaction);
    event transferCreated(string ticker, address sender, address receiver, uint256 amount, uint256 id, uint256 approvals, uint256 timeOfTransaction);
    event transferCancelled(string ticker, address sender, address receiver, uint256 amount, uint256 id, uint256 approvals, uint256 timeOfTransaction);
    event transferApproved(string ticker, address sender, address receiver, uint256 amount, uint256 id, uint256 approvals, uint256 timeOfTransaction);
    event fundsTransfered(string ticker, address sender, address receiver, uint256 amount, uint256 id, uint256 approvals, uint256 timeOfTransaction);
    event tokenAdded(address addedBy, string ticker, address tokenAddress, uint256 timeOfTransaction);

    modifier onlyOwners() {
        bool isOwner = false;
        for (uint256 i = 0; i < walletowners.length; i++) {
            if (walletowners[i] == msg.sender) {
                isOwner = true;
                break;
            }
        }
        require(isOwner == true, "hanya wallet owners yang bisa memanggil function ini");
        _;
    }

    modifier tokenExists(string memory ticker) {
        if (keccak256((bytes(ticker))) != keccak256(bytes("ETH"))) {
            require(tokenMapping[ticker].tokenAddress != address(0), "token tidak tersedia");
        }
        _;
    }

    modifier mutexApplied() {
        require(!locked, "Reentrancy guard: locked");
        locked = true;
        _;
        locked = false;
    }

    function addToken(string memory ticker, address _tokenAddress) public onlyOwners {
        for (uint256 i = 0; i < tokenList.length; i++) {
            require(keccak256(bytes(tokenList[i])) != keccak256(bytes(ticker)), "tidak dapat add tokens duplikat");
        }
        require(keccak256(bytes(ERC20(_tokenAddress).symbol())) == keccak256(bytes(ticker)), "token tidak tersedia pada ERC20");
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
        for (uint256 i = 0; i < walletowners.length; i++) {
            if (walletowners[i] == owner) {
                revert("cannot add duplicate owners");
            }
        }
        walletowners.push(owner);
        emit walletOwnerAdded(msg.sender, owner, block.timestamp);
        setMultisigContractAdress(walletAddress);
        callAddOwner(owner, _address);
    }

    function removeWalletOwner(address owner, address walletAddress, address _address) public onlyOwners {
        bool hasBeenFound = false;
        uint256 ownerIndex;
        for (uint256 i = 0; i < walletowners.length; i++) {
            if (walletowners[i] == owner) {
                hasBeenFound = true;
                ownerIndex = i;
                break;
            }
        }
        require(hasBeenFound == true, "wallet owner tidak terdetect");
        walletowners[ownerIndex] = walletowners[walletowners.length - 1];
        walletowners.pop();
        emit walletOwnerRemoved(msg.sender, owner, block.timestamp);
        setMultisigContractAdress(walletAddress);
        callRemoveOwner(owner, _address);
    }

    function deposit(string memory ticker, uint256 amount) public payable onlyOwners mutexApplied {
        require(balance[msg.sender][ticker] >= 0, "tidak dapat deposit value 0");
        require(!withdrawing[msg.sender], "proses sedang berlangsung");
        withdrawing[msg.sender] = true;
        if (keccak256(bytes(ticker)) == keccak256(bytes("ETH"))) {
            balance[msg.sender]["ETH"] += msg.value;
        } else {
            require(tokenMapping[ticker].tokenAddress != address(0), "token tidak tersedia");
            bool transferSuccess = IERC20(tokenMapping[ticker].tokenAddress).transferFrom(msg.sender, address(this), amount);
            require(transferSuccess, "ERC20 transfer failed");
            balance[msg.sender][ticker] += amount;
        }
        emit fundsDeposited(ticker, msg.sender, msg.value, depositId, block.timestamp);
        withdrawing[msg.sender] = false;
        depositId++;
    }

    function initiateWithdrawal(string memory ticker, uint256 _amount) public onlyOwners {
        require(_amount > 0, "Amount must be greater than 0");
        require(balance[msg.sender][ticker] >= _amount, "balance tidak cukup");
        require(!withdrawalInProcess[msg.sender], "Withdrawal request in process");
        if (keccak256(bytes(ticker)) != keccak256(bytes("ETH"))) {
            require(tokenMapping[ticker].tokenAddress != address(0), "token tidak tersedia");
        }
        balancesToWithdraw[msg.sender] = _amount;
        tickerToWithdraw[msg.sender] = ticker;
        withdrawalInProcess[msg.sender] = true;
    }

    function withdraw() public onlyOwners mutexApplied {
        require(withdrawalInProcess[msg.sender], "Tidak ada withdrawal request");
        require(!withdrawing[msg.sender], "proses sedang berlangsung");
        withdrawing[msg.sender] = true;
        bool transferSuccess = false;
        uint256 amount = balancesToWithdraw[msg.sender];
        string memory ticker = tickerToWithdraw[msg.sender];
        balancesToWithdraw[msg.sender] = 0;
        tickerToWithdraw[msg.sender] = "";
        withdrawalInProcess[msg.sender] = false;
        if (keccak256(bytes(ticker)) == keccak256(bytes("ETH"))) {
            // payable(msg.sender).transfer(amount);
            (transferSuccess,) = payable(msg.sender).call{value: amount}("");
        } else {
            require(tokenMapping[ticker].tokenAddress != address(0), "token tidak tersedia");
            transferSuccess = IERC20(tokenMapping[ticker].tokenAddress).transfer(msg.sender, amount);
        }
        require(transferSuccess, "ERC20 transfer failed");
        balance[msg.sender][ticker] -= amount;
        emit fundsWithdrawed(ticker, msg.sender, amount, withdrawalId, block.timestamp);
        withdrawing[msg.sender] = false;
        withdrawalId++;
    }

    function createTransferRequest(string memory ticker, address payable receiver, uint256 amount) public onlyOwners tokenExists(ticker) {
    require(balance[msg.sender][ticker] >= amount, "funds tidak cukup untuk create transfer");
    for (uint256 i = 0; i < walletowners.length; i++) {
        require(walletowners[i] != receiver, "tidak bisa transfer funds pada wallet pribadi");
    }

    balance[msg.sender][ticker] -= amount;

    address[] memory emptyApprovers;  // Create an empty array of approvers
    transferRequests.push(Transfer(ticker, msg.sender, receiver, amount, transferId, 0, block.timestamp, emptyApprovers));
    transferId++;
    emit transferCreated(ticker, msg.sender, receiver, amount, transferId, 0, block.timestamp);
}

    

    function cancelTransferRequest(string memory ticker, uint256 id) public onlyOwners {
        bool hasBeenFound = false;
        uint256 transferIndex = 0;
        for (uint256 i = 0; i < transferRequests.length; i++) {
            if (transferRequests[i].id == id) {
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

    function approveTransferRequest(string memory ticker, uint256 id) public onlyOwners {
    bool hasBeenFound = false;
    uint256 transferIndex = 0;
    for (uint256 i = 0; i < transferRequests.length; i++) {
        if (transferRequests[i].id == id) {
            hasBeenFound = true;
            break;
        }
        transferIndex++;
    }

    require(hasBeenFound, "hanya transfer creator yang dapat cancel");
    require(!isApprover(msg.sender, transferRequests[transferIndex].approvers), "tidak dapat approve pada transaksi transfer kedua kalinya");
    require(transferRequests[transferIndex].sender != msg.sender, "tidak dapat approve pada transaction pribadi");

    transferRequests[transferIndex].approvers.push(msg.sender);
    transferRequests[transferIndex].approvals++;

    emit transferApproved(ticker, msg.sender, transferRequests[transferIndex].receiver, transferRequests[transferIndex].amount, transferRequests[transferIndex].id, transferRequests[transferIndex].approvals, transferRequests[transferIndex].timeOfTransaction);
    if (transferRequests[transferIndex].approvals >= threshold) {
        transferFunds(ticker, transferIndex);
    }
}

function isApprover(address _approver, address[] memory _approvers) internal pure returns (bool) {
    for (uint256 i = 0; i < _approvers.length; i++) {
        if (_approvers[i] == _approver) {
            return true;
        }
    }
    return false;
}


    function transferFunds(string memory ticker, uint256 id) private mutexApplied {
        require(!withdrawing[msg.sender], "proses sedang berlangsung");
        withdrawing[msg.sender] = true;
        bool transferSuccess = false;
        balance[transferRequests[id].receiver][ticker] += transferRequests[id].amount;
        if (keccak256(bytes(ticker)) == keccak256(bytes("ETH"))) {
            // transferRequests[id].receiver.transfer(transferRequests[id].amount);
            (transferSuccess,) = transferRequests[id].receiver.call{value: transferRequests[id].amount}("");
        } else {
            transferSuccess = IERC20(tokenMapping[ticker].tokenAddress).transfer(transferRequests[id].receiver, transferRequests[id].amount);
        }
        require(transferSuccess, "ERC20 transfer failed");
        emit fundsTransfered(ticker, msg.sender, transferRequests[id].receiver, transferRequests[id].amount, transferRequests[id].id, transferRequests[id].approvals, transferRequests[id].timeOfTransaction);
        withdrawing[msg.sender] = false;
        transferRequests[id] = transferRequests[transferRequests.length - 1];
        transferRequests.pop();
    }

    function getApprovals(uint256 id) public onlyOwners view returns (bool) {
    address[] memory approvers = transferRequests[id].approvers;
    for (uint256 i = 0; i < approvers.length; i++) {
        if (approvers[i] == msg.sender) {
            return true;
        }
    }
    return false;
}


    function getTransferRequests() public onlyOwners view returns (Transfer[] memory) {
        return transferRequests;
    }

    function getBalance(string memory ticker) public view returns (uint256) {
        return balance[msg.sender][ticker];
    }

    function getApprovalLimit() public onlyOwners view returns (uint256) {
        return threshold;
    }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getWalletOwners() public view onlyOwners returns (address[] memory) {
        return walletowners;
    }

    function getTokenList() public view returns (string[] memory) {
        return tokenList;
    }
}
