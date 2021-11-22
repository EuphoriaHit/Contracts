// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
//SafeMath in this contract IS USED ONLY IN RISKY CALCULATIONS . However, the use of this library is not mandatory on solidity 0.8.0 or higher
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract IDO is Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // <================================ CONSTANTS ================================>
    uint8 constant TEAM_PERCENTAGE = 15;
    uint8 constant TEAM_DURATION_IN_MONTHS = 6;
    uint8 constant MARKETING_PERCENTAGE = 10;
    uint8 constant MARKETING_DURATION_IN_MONTHS = 6;
    uint8 constant RESERVE_PERCENTAGE = 20;
    uint8 constant RESERVE_DURATION_IN_MONTHS = 12;
    uint8 constant PUBLIC_PERCENTAGE = 2;
    
    // <================================ MODIFIERS ================================>
    modifier contractNotStarted() {
        require(_contractStarted == false, "IDO: The IDO contract has already started");
        _;
    }

    struct Share {
        address shareAddress;
        uint256 share;
        uint256 releaseTime;
    }
    
    // <================================ CONSTRUCTOR AND INITIALIZER ================================>

    constructor(
        address euphAddress, 
        address busdAddress,
        address teamAddress,
        address marketingAddress,
        address reserveAddress,
        uint256 euphPrice) 
    {
        require(euphAddress != address(0), "IDO: Euphoria token address must not be zero");
        require(busdAddress != address(0), "IDO: BUSD token address must not be zero");
        require(teamAddress != address(0), "IDO: Team address must not be zero");
        require(marketingAddress != address(0), "IDO: Marketing address must not be zero");
        require(reserveAddress != address(0), "IDO: Reserve address must not be zero");
        _euph = IERC20(euphAddress);
        _busd = IERC20(busdAddress);
        uint256 totalSupply = _euph.totalSupply();
        
        _teamShare.shareAddress = teamAddress;
        _marketingShare.shareAddress = marketingAddress;
        _reserveShare.shareAddress = reserveAddress;
        
        _teamShare.releaseTime = _monthsToTimestamp(TEAM_DURATION_IN_MONTHS).add(block.timestamp);
        _marketingShare.releaseTime = _monthsToTimestamp(MARKETING_DURATION_IN_MONTHS).add(block.timestamp);
        _reserveShare.releaseTime = _monthsToTimestamp(RESERVE_DURATION_IN_MONTHS).add(block.timestamp);
        
        _teamShare.share = totalSupply.mul(TEAM_PERCENTAGE).div(100);
        _marketingShare.share = totalSupply.mul(MARKETING_PERCENTAGE).div(100);
        _reserveShare.share = totalSupply.mul(RESERVE_PERCENTAGE).div(100);
        _publicShare = totalSupply.mul(PUBLIC_PERCENTAGE).div(100);
        
        
        _euphPrice = euphPrice;
        _pause();
    }
    
    function initialize()
        external
        onlyOwner
        contractNotStarted
    {
        require(_contractStarted == false, "IDO: The IDO contract has been already initialized");
        uint256 totalSupply = _euph.totalSupply();
        uint256 totalPercentage = TEAM_PERCENTAGE + PUBLIC_PERCENTAGE + RESERVE_PERCENTAGE + MARKETING_PERCENTAGE;
        uint256 initialSupply = totalSupply.mul(totalPercentage).div(100); //(totalSupply * totalPercentage) / 100;
        _contractStarted = true;
        _startDate = block.timestamp - (block.timestamp % 86400);
        transferTokensToContract(initialSupply);
        _unpause();
    }

    IERC20 public _euph;
    IERC20 public _busd;
    uint256 public _startDate;
    uint256 public _publicShare;
    Share public _teamShare;
    Share public _marketingShare;
    Share public _reserveShare;
    uint256 public _euphPrice; //In full decimal precision. Example: 0.0009 Busd = 900000000000000;
    bool _contractStarted;

    // <================================ EXTERNAL FUNCTIONS ================================>

    function buyTokens(uint256 busdAmount) 
    external
    whenNotPaused
    returns(bool) {
        require(_publicShare > 0, "IDO: There are no public tokens left available for sale");
        address buyer = _msgSender();
        require(buyer != address(0), "IDO: Token issue to Zero address is prohibited");
        require(busdAmount > 0, "IDO: Provided BUSD amount must be higher than 0");
        uint256 tokensAmountToIssue = busdAmount.div(_euphPrice); //busdAmount / _euphPrice; //The total number of full tokens that will be issued. 1 Full EUPH token = 1000 tokens in full decimal precision
        require(tokensAmountToIssue > 0, "IDO: Provided price value is not sufficient to by even one EUPH token");
        uint256 totalPrice = tokensAmountToIssue.mul(_euphPrice); //tokensAmountToIssue * _euphPrice; //Total price in BUSD to buy specific number of EUPH tokens
        uint256 kiloTokensToIssue = toKiloToken(tokensAmountToIssue); //Total amount of EUPH tokens (in full decimal precision) to issue

        require(_issueTokens(buyer, totalPrice, kiloTokensToIssue), "IDO: Token transfer failed");
        
        return true;
    }

    function withdrawTeamShare() external onlyOwner whenNotPaused {
        require(_withdrawShare(_teamShare));
    }

    function withdrawMarketingShare() external onlyOwner whenNotPaused {
        require(_withdrawShare(_marketingShare));
    }

    function withdrawReserveShare() external onlyOwner whenNotPaused {
        require(_withdrawShare(_reserveShare));
    }

    // <================================ ADMIN FUNCTIONS ================================>

    function pauseContract() external onlyOwner whenNotPaused
    {
        _pause();
    }

    function unPauseContract() external onlyOwner whenPaused
    {
        _unpause();
    }

    function changePrice(uint256 newEuphPrice) external onlyOwner whenPaused {
        _euphPrice = newEuphPrice;
    }

    function transferTokensToContract(uint256 amount) public onlyOwner
    {
        _euph.safeTransferFrom(_msgSender(), address(this), amount);
        emit TokensTransferedToStakingBalance(_msgSender(), amount);
    }

    function withdrawBUSD() external onlyOwner returns (bool) {
        address owner = _msgSender();
        uint256 balanceBUSD = _busd.balanceOf(address(this));
        require(balanceBUSD > 0, "IDO: Nothing to withdraw. Ido contract's BUSD balance is empty");
        _busd.safeTransfer(owner, balanceBUSD);
        return true;
    }

    function finalize() external onlyOwner {
        address owner = _msgSender();
        uint256 balanceBUSD = _busd.balanceOf(address(this));
        uint256 balanceEUPH = _euph.balanceOf(address(this));
        if(balanceBUSD > 0) _busd.safeTransfer(owner, balanceBUSD);
        if(balanceEUPH > 0)  _euph.safeTransfer(owner, balanceEUPH);
        selfdestruct(payable(_msgSender()));
    }

    // <================================ INTERNAL & PRIVATE FUNCTIONS ================================>
    function _withdrawShare(Share memory share) internal returns(bool) {
        require(block.timestamp >= share.releaseTime, "IDO: Time is not up. Cannot release share");
        _euph.safeTransfer(share.shareAddress, share.share);

        emit ShareReleased(share.shareAddress, share.share);
        return true;
    }
    
    function _issueTokens(address buyer, uint256 busdToPay, uint256 euphToIssue) private returns(bool) {
        require(_busd.allowance(buyer, address(this)) >= busdToPay, "IDO: Not enough allowance to perform transfer. Please be sure to approve sufficient tokens amount");
        _busd.safeTransferFrom(buyer, address(this), busdToPay);
        _euph.safeTransfer(buyer, euphToIssue);
        _publicShare = _publicShare.sub(euphToIssue);

        emit TokensPurchased(buyer, busdToPay, euphToIssue);
        return true;
    }

    function _monthsToTimestamp(uint256 months) internal pure returns(uint256) {
        return months.mul(2592000);
    }

    function toKiloToken(uint256 amount) internal pure returns(uint256) {
        return amount.mul((10 ** decimals()));
    }

    function decimals() internal pure returns(uint8) {
        return 3;
    }
    // <================================ EVENTS ================================>

    event TokensTransferedToStakingBalance(address indexed sender, uint256 indexed amount);

    event ShareReleased(address indexed beneficiary, uint256 indexed amount);

    event TokensPurchased(address indexed buyer, uint256 spentAmount, uint256 indexed issuedAmount);
}