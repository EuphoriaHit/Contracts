// BSC bridge
// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//SafeMath in this contract IS USED ONLY IN RISKY CALCULATIONS . However, the use of this library is not mandatory on solidity 0.8.0 or higher
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// IERC20P enhances IERC20 interface with mint burn and burnFrom methods. P stands for Plus (or Enhanced)
interface IERC20P is IERC20 {
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}

contract BridgeEth is Ownable, Pausable {
    using SafeMath for uint256;
    IERC20P private _token;
    uint256 _mintedTokensAmount; // Represents the total amount of unlocked tokens
    uint256 _maxTotalSupply; // Maximum allowed amount of tokens
    mapping(uint256 => bool) public _convertProcess;
    bool _contractStarted;

    bytes32 private BURN;
    bytes32 private MINT;
    bytes32 private VALIDATOR;

    event TokenBurned(
        address from,
        uint256 amount,
        uint256 date,
        bytes32 type_sign,
        bytes32 validator_sign
    );

    event TokenMinted(
        address from,
        uint256 amount,
        uint256 date,
        bytes32 type_sign,
        bytes32 validator_sign
    );

    constructor(address tokenAddress, string memory validator, uint256 maxTotalSupply)
    {
        _token = IERC20P(tokenAddress);
        BURN = keccak256("BURN");
        MINT = keccak256("MINT");
        VALIDATOR = keccak256(abi.encodePacked(validator));
        _mintedTokensAmount = 0;
        _maxTotalSupply = maxTotalSupply;
        _contractStarted = true;
    }

    function getMintedTokensAmount() view external returns(uint256) {
        return _mintedTokensAmount;
    }

    function burnToken(uint256 amount) external whenNotPaused {
        address sender = _msgSender();
        require(sender != address(0), "ETH bridge: Zero address is not allowed");
        require(amount > 0, "ETH bridge: Burn of 0 tokens is prohibited");
        require(
            _mintedTokensAmount >= amount,
            "ETH bridge: cannot burn more than total amount of minted tokens"
        );
        _burn(sender, amount);
        _mintedTokensAmount = _mintedTokensAmount.sub(amount);

        emit TokenBurned(sender, amount, block.timestamp, BURN, VALIDATOR);
    }

    function mintToken(
        address to,
        uint256 amount,
        uint256 nonce,
        string calldata validator
    ) external onlyOwner whenNotPaused {
        require(to != address(0), "ETH bridge: Zero address is not allowed");
        require(amount > 0, "ETH bridge: Mint of 0 tokens is prohibited");
        require(
            _convertProcess[nonce] == false,
            "ETH bridge: Transfer with similar nonce has already been processed before"
        );
        require(
            VALIDATOR == keccak256(abi.encodePacked(validator)),
            "ETH bridge: Unkown validator off-chain"
        );
        require(
            _maxTotalSupply >= _mintedTokensAmount.add(amount),
            "ETH bridge: Cannot mint more than maximum total supply amount"
        );
        _convertProcess[nonce] = true;
        _mint(to, amount);
        _mintedTokensAmount = _mintedTokensAmount.add(amount);

        emit TokenMinted(to, amount, block.timestamp, MINT, VALIDATOR);
    }

    function changeToken(address tokenAddress) external onlyOwner whenPaused {
        require(
            address(_token) != tokenAddress,
            "ETH bridge: Same token can not be changed"
        );
        _token = IERC20P(tokenAddress);
    }

    function changeValidator(string memory validator) external onlyOwner whenPaused {
        require(
            VALIDATOR != bytes32(abi.encode(validator)),
            "ETH bridge: Same validator can not be changed"
        );
        VALIDATOR = bytes32(abi.encode(validator));
    }

    function changeMintedTokensAmount(uint256 amount) external onlyOwner whenPaused {
        require(_mintedTokensAmount != amount, "ETH bridge: Change of same amount is prohibited");
        _mintedTokensAmount = amount;
    }

    function pauseContract() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpauseContract() external onlyOwner whenPaused {
        _unpause();
    }

    function _withdrawToken(address to, uint256 amount) external onlyOwner {
        require(_token.transfer(to, amount), "ETH Bridge: Token transfer failed");
    }

    function _burn(address to, uint256 amount) private {
        _token.burnFrom(to, amount);
    }

    function _mint(address to, uint256 amount) private {
        _token.mint(to, amount);
    }
}
