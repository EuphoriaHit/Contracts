// Token Pool
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBEP20 is IERC20 {}

contract BridgeBsc is Ownable, Pausable {
    IBEP20 private _token;
    uint256 _unlockedTokensAmount; // Represents the total amount of unlocked tokens
    uint256 _maxTotalSupply; // Maximum allowed amount of tokens
    mapping(uint256 => bool) public _convertProcess;

    bytes32 private LOCK;
    bytes32 private UNLOCK;
    bytes32 public VALIDATOR;

    bool _isPaused;

    event TokenLocked(
        address from,
        uint256 amount,
        uint256 date,
        bytes32 type_sign,
        bytes32 validator_sign
    );

    event TokenUnlocked(
        address from,
        uint256 amount,
        uint256 date,
        bytes32 type_sign,
        bytes32 validator_sign
    );

    constructor(address tokenAddress, string memory validator)
    {
        _token = IBEP20(tokenAddress);
        LOCK = keccak256("LOCK");
        UNLOCK = keccak256("UNLOCK");
        VALIDATOR = keccak256(abi.encodePacked(validator));
        _unlockedTokensAmount = _token.totalSupply();
        _maxTotalSupply = _unlockedTokensAmount;
    }

    function getUnlockedTokensAmount() view external returns(uint256) {
        return _unlockedTokensAmount;
    }

    function lockToken(uint256 amount) external whenNotPaused {
        address sender = _msgSender();
        require(sender != address(0), "BSC bridge: Zero address is not allowed");
        require(amount > 0, "BSC bridge: Lock of 0 tokens is prohibited");
        require(
            _unlockedTokensAmount >= amount,
            "BSC bridge: cannot lock more than total amount of unlocked tokens"
        );
        _lock(sender, address(this), amount);
        _unlockedTokensAmount -= amount;
        emit TokenLocked(sender, amount, block.timestamp, LOCK, VALIDATOR);
    }

    function unlockToken(
        address to,
        uint256 amount,
        uint256 nonce,
        string memory validator
    ) external onlyOwner whenNotPaused {
        require(to != address(0), "BSC bridge: Zero address is not allowed");
        require(amount > 0, "BSC bridge: Unlock of 0 tokens is prohibited");
        require(
            _convertProcess[nonce] == false,
            "BSC bridge: Transfer with similar nonce has already been processed before"
        );
        require(
            VALIDATOR == keccak256(abi.encodePacked(validator)),
            "BSC bridge: Unkown validator off-chain"
        );
        
        require(
            _maxTotalSupply >= _unlockedTokensAmount + amount,
            "BSC bridge: Cannot unlock more than maximum total supply amount"
        );
        
        _convertProcess[nonce] = true;
        _unlockedTokensAmount += amount;
        _unlockToken(to, amount);
        emit TokenUnlocked(to, amount, block.timestamp, UNLOCK, VALIDATOR);
    }

    function changeToken(address tokenAddress) external onlyOwner whenPaused {
        require(
            address(_token) != tokenAddress,
            "BSC bridge: Same token can not be changed"
        );
        _token = IBEP20(tokenAddress);
    }

    function changeValidator(string memory validator) external onlyOwner whenPaused {
        require(
            VALIDATOR != keccak256(abi.encodePacked(validator)),
            "BSC bridge: Same validator can not be changed"
        );
        VALIDATOR = keccak256(abi.encodePacked(validator));
    }

    function changeUnlockedTokensAmount(uint256 amount) external onlyOwner whenPaused {
        require(_unlockedTokensAmount != amount, "BSC bridge: Change of same amount is prohibited");
        _unlockedTokensAmount = amount;
    }

    function pauseContract() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpauseContract() external onlyOwner whenPaused {
        _unpause();
    }

    function _lock(
        address from,
        address to,
        uint256 amount
    ) private {
        require(_token.transferFrom(from, to, amount), "BSC Bridge: Token transfer failed");
    }

    function _unlockToken(address to, uint256 amount) private {
        require(_token.transfer(to, amount), "BSC Bridge: Token transfer failed");
    }
}
