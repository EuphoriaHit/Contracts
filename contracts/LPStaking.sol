// SPDX-License-Identifier: MIT
// <-- !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! THIS CONTRACT IS NOT FINAL !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! -->
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IPancakePair.sol";

interface Staking {
  function createStakeLP(address stakeHolder, uint256 stakeAmount) external;
  function unStakeLP(address stakeHolder) external;
}

//This smart contract's reward distribution algorithm was based on this article
//https://uploads-ssl.webflow.com/5ad71ffeb79acc67c8bcdaba/5ad8d1193a40977462982470_scalable-reward-distribution-paper.pdf

contract LPStaking is Ownable{
    using SafeERC20 for IERC20;
    uint64 constant PRECISION = 1000000000000000000;

    modifier contractExpired() {
        uint256 currentDay = _getCurrentDay();
        if(_totalStakes == 0) {
            _daysInPause += currentDay - _lastActiveDay;
            _lastActiveDay = currentDay;
        }
        require(currentDay - _daysInPause >= _contractDurationInDays, "Staking: The staking contract is not yet expired");
        _;
    }

    modifier contractNotExpired() {
        uint256 currentDay = _getCurrentDay();
        if(_totalStakes == 0) {
            _daysInPause += currentDay - _lastActiveDay;
            _lastActiveDay = currentDay;
        }
        require(currentDay - _daysInPause < _contractDurationInDays, "Staking: The staking contract has already expired");
        _;
    }

    modifier contractStarted() {
        require(_stakingStarted == true, "Staking: The staking contract has not started yet");
        _;
    }

    modifier contractNotStarted() {
        require(_stakingStarted == false, "Staking: The staking contract has already started");
        _;
    }

    // <================================ CONSTRUCTOR AND INITIALIZER ================================>

    constructor(uint256 supplyPercentage, uint16 durationInDays, address tokenAddress) {
        _setToken(tokenAddress);
        _setSupplyAndDuration(supplyPercentage, durationInDays);
    }

    function changeSupplyAndDuration(uint256 supplyPercentage, uint16 durationInDays) external onlyOwner contractNotStarted {
        _setSupplyAndDuration(supplyPercentage, durationInDays);
    }

    function changeToken(address newTokenAddress) external onlyOwner contractNotStarted{
        _setToken(newTokenAddress);
    }

    function initialize()
        external
        onlyOwner
        contractNotStarted
    {
        require(_stakingStarted == false, "Staking: The staking contract has been already initialized");
        _stakingStarted = true;
        _startDate = block.timestamp - (block.timestamp % 1 days );
        transferTokensToContract(_initialSupply);
    }

    // <================================ END OF CONSTRUCTOR AND INITIALIZER ================================>
    bool private _stakingStarted; // The boolean to check if the staking contract has been initialized and started the work process
    bool private _distributionEnded; // This boolean is used to control the work of distribuiteRewards() function
    uint256 public _contractDurationInDays; // Duration of contract in days
    mapping(address => mapping(uint256 => uint256)) private _distributedRewardsSnapshot; // S0 value in the Article Paper
    mapping(address => mapping(uint256 => uint256)) private _stake; // Keeps record of user's made stakings. Note that every new staking is considered as a seperate _stake transaction
    mapping(address => uint256) private _stakesCount; // Total number of accomplished stakes by a specific user
    uint256 private _distributedRewards; // S value in the Article Paper
    uint256 public _dailyReward; // Amount of tokens that will be distributed among all users in 1 Day 
    uint256 public _initialSupply; // Amount of tokens allocated for Staking contract use
    uint256 public _startDate; // Timestamp of the start day of the contract
    uint256 public _totalStakes; // Represents the total amount of staked Tokens. T value in the Article Paper. Find source of the article on top comment
    uint256 private _previousTotalStakes; // Represents the previous state of total amount of staked Tokens 
    uint256 private _lastActiveDay; // Represents the day of last activity such as createStake, unStake
    uint256 public _stakeHoldersCount; // Total number of stake holders (users)
    uint256 public _daysInPause; // Number of days with no active stakes. If there were no stakes on a specific day, then no reward is distributed and the duration of contract is extended to plus one day
    uint256 private _totalRewards; // The total amount of rewards that have already been distributed
    IPancakeRouter02 private _pancakeswapRouter;
    IPancakePair private _pancakeswapPair;
    IERC20 private _euph;
    IERC20 private _busd;
    mapping(address => uint256) _pancakeswapUserLPTokens;
    
    // <================================ EVENTS ================================>
    event StakeCreated(address indexed stakeHolder, uint256 indexed stake);

    event UnStaked(address indexed stakeHolder, uint256 indexed withdrawAmount);

    event TokensTransferedToStakingBalance(address indexed sender, uint256 indexed amount);

    event AddedLiquidityOnPancakeswap(uint256 sentEUPH, uint256 sentBUSD, uint256 liquidity);

    event RemovedLiquidityOnPancakeswap(uint256 receivedEUPH, uint256 receivedBUSD);
    // <================================ EXTERNAL FUNCTIONS ================================>

    // <<<================================= GETTERS =================================>>>
    //THIS IS A CALL FUNCTION THAT RETURNS THE EXPECTED REWARD VALUE THAT USER WILL RECEIVE 
    function calculateReward() external contractStarted view returns (uint256) {
        address _stakeHolder = _msgSender();
        uint256 userStakesCount = _stakesCount[_stakeHolder];
        uint256 reward;
        uint256 distributedRewards = _distributedRewards;
        uint256 withdrawAmount;
        uint256 totalDeposited;
        uint256 currentDay = _getCurrentDay();
        uint256 passedDays;
        require(isStakeHolder(_stakeHolder), "Staking: This user must be a stake holder");

        // Same code as in distributeRewards() method. However, it does not alter contract's state
        if(!_distributionEnded)
        {
            if(_lastActiveDay != currentDay || _lastActiveDay != _contractDurationInDays + _daysInPause){
                if (currentDay - _daysInPause > _contractDurationInDays) {
                    passedDays = _contractDurationInDays - (_lastActiveDay - _daysInPause);
                } else {
                    passedDays = currentDay - _lastActiveDay;
                }

                distributedRewards += (_dailyReward * passedDays * PRECISION) / _previousTotalStakes;
            }
        }

        // Calculation of User reward
        for(uint i = 0; i < userStakesCount; i++) {
            uint256 deposited = _stake[_stakeHolder][i];
            reward += (deposited * (distributedRewards - _distributedRewardsSnapshot[_stakeHolder][i])) / PRECISION;
            totalDeposited += deposited;
        }

        if(reward > 0) {
            withdrawAmount = reward + totalDeposited;
        } else {
            withdrawAmount = totalDeposited;
        }

        return withdrawAmount;
    }

    function getUserStakesAmount(address stakeHolder) external view returns(uint256) {
        uint256 result;

        for(uint i = 0; i < _stakesCount[stakeHolder]; i++) {
            result += _stake[stakeHolder][i];
        }

        return result;
    }

    // <<<================================= END OF GETTERS =================================>>>

    function transferTokensToContract(uint256 amount) public onlyOwner
    {
        address owner = _msgSender();
        _euph.safeTransferFrom(owner, address(this), amount);
        emit TokensTransferedToStakingBalance(owner, amount);
    }

   function isStakeHolder(address stakeholder) public view returns(bool) {
        if(_stakesCount[stakeholder] != 0) {
            return true;
        }
       
       return false;
   }

    function addLiquidityPancake(uint256 amountEUPH, uint256 amountBUSD) external {
        address sender = _msgSender();
        require(sender != address(0), "Staking: No zero address is allowed");
        (uint256 sentEUPH, uint256 sentBUSD, uint256 liquidity) = _addLiquidityPancake(address(this), amountEUPH, amountBUSD);
        _pancakeswapUserLPTokens[sender] += liquidity;
        require(_createStake(sender, liquidity), "Staking: Couldn't create stake");

        emit AddedLiquidityOnPancakeswap(sentEUPH, sentBUSD, liquidity);
    }

    function removeLiquidityPancake() external {
        address sender = _msgSender();
        require(isStakeHolder(sender), "Staking: There is not any stake holder with provided address");
        (uint256 receivedEUPH, uint256 receivedBUSD) = _removeLiquidityPancake(sender);
        delete _pancakeswapUserLPTokens[sender];
        uint256 earnedReward = _unStake(sender);
        _euph.safeTransfer(sender, receivedEUPH + earnedReward);
        _busd.safeTransfer(sender, receivedBUSD);

        emit RemovedLiquidityOnPancakeswap(receivedEUPH, receivedBUSD);
    }

    function finalize() external onlyOwner contractStarted contractExpired {
        address owner = _msgSender();
        uint256 balanceEUPH = _euph.balanceOf(address(this));
        if(balanceEUPH > 0)  _euph.safeTransfer(owner, balanceEUPH);
        selfdestruct(payable(owner));
    }

    // <================================ INTERNAL FUNCTIONS ================================>

    function decimals() internal pure returns(uint8) {
        return 3;
    }

    function toKiloToken(uint256 amount) internal pure returns(uint256) {
        return amount * (10 ** decimals());
    }

    function balanceOfContract()
       internal
       view
       returns(uint256)
   {
       return _euph.balanceOf(address(this));
   }

    // <================================ PRIVATE FUNCTIONS ================================>

    function removeStakeHolder(address stakeHolder) private contractStarted {
        for(uint i = 0; i < _stakesCount[stakeHolder]; i++) {
            delete _stake[stakeHolder][i];
            delete _distributedRewardsSnapshot[stakeHolder][i];
        }
        delete _stakesCount[stakeHolder];
        
        _stakeHoldersCount -= 1;
   }

   function _setSupplyAndDuration(uint256 supplyPercentage, uint16 durationInDays) private {
       require(durationInDays > 0, "Staking: Duration cannot be a zero value");
       require(supplyPercentage > 0 && supplyPercentage <= 100, "Staking: Supply percentage can be in a range between 0 and 100");
        _contractDurationInDays = durationInDays;
        _initialSupply = (_euph.totalSupply() * supplyPercentage) / 100;
        _dailyReward = _initialSupply / _contractDurationInDays;
   }

   function _setToken(address newTokenAddress) private {
        require(
            address(_euph) != newTokenAddress,
            "Staking: Cannot change token of same address"
        );
        _euph = IERC20(newTokenAddress);
    }

    function _getCurrentDay() private view returns (uint256) 
    {
        return (block.timestamp - _startDate) / 1 days;    
    }

    function _distributeRewards()
        private
    {
        uint256 currentDay = _getCurrentDay();
        uint256 passedDays;

        if(_lastActiveDay == currentDay || _lastActiveDay == _contractDurationInDays + _daysInPause) return;
        
        if (currentDay - _daysInPause > _contractDurationInDays) {
            _distributionEnded = true;
            passedDays = _contractDurationInDays - (_lastActiveDay - _daysInPause);
        } else {
            passedDays = currentDay - _lastActiveDay;
        }

        _distributedRewards += (_dailyReward * passedDays * PRECISION) / _previousTotalStakes;

        _lastActiveDay = currentDay;
    }

    function _createStake(address stakeHolder, uint256 stakeAmount) private returns (bool) {
        require(stakeAmount >= toKiloToken(10000), "Staking: Minimal stake value is 10 000 euphoria tokens");
        uint256 stakeId = _stakesCount[stakeHolder];
        uint256 currentDay = _getCurrentDay();

        if(!isStakeHolder(stakeHolder))
        { 
            _stakeHoldersCount += 1;
        }
        if(!_distributionEnded) {
            if(currentDay != _lastActiveDay)
            {
                _distributeRewards();
            }
        }

        _stake[stakeHolder][stakeId] = stakeAmount;
        _distributedRewardsSnapshot[stakeHolder][stakeId] = _distributedRewards;
        _stakesCount[stakeHolder] += 1;
        
        _totalStakes += stakeAmount;

        if(_previousTotalStakes == 0 || currentDay == _lastActiveDay) {
            _previousTotalStakes = _totalStakes;
        }

        emit StakeCreated(stakeHolder, stakeAmount);

        return true;
   }

   function _unStake(address stakeHolder) private returns (uint256) {
        require(stakeHolder != address(0), "Staking: Zero address is prohibited");
        require(isStakeHolder(stakeHolder), "Staking: There is not any stake holder with provided address");
        uint256 userStakesCount = _stakesCount[stakeHolder];
        uint256 reward;
        uint256 withdrawAmount;
        uint256 totalDeposited;

        if(!_distributionEnded)
        {
            if(_getCurrentDay() != _lastActiveDay) {
                _distributeRewards();
            }
        }

        // Calculation of User reward
        for(uint i = 0; i < userStakesCount; i++) {
            uint256 deposited = _stake[stakeHolder][i];
            reward += (deposited * (_distributedRewards - _distributedRewardsSnapshot[stakeHolder][i])) / PRECISION;
            totalDeposited += deposited;
        }

        _totalStakes -= totalDeposited;
        _previousTotalStakes = _totalStakes;

        if(reward > 0) {
            _totalRewards += reward;
            withdrawAmount = (_isContractExpired() && _stakeHoldersCount == 1) ? _euph.balanceOf(address(this)) : reward + totalDeposited;
        } else {
            withdrawAmount = 0;
        }

        removeStakeHolder(stakeHolder);

        emit UnStaked(stakeHolder, withdrawAmount);

        return withdrawAmount;
    }

    function _isContractExpired() private view returns(bool) {
        return _getCurrentDay() - _daysInPause >= _contractDurationInDays;
    }

    function _addLiquidityPancake(address lpUser, uint256 amountEUPH, uint256 amountBUSD) private returns (uint256 sentEUPH, uint256 sentBUSD, uint256 liquidity){
        (sentEUPH, sentBUSD, liquidity) = _pancakeswapRouter.addLiquidity(
            address(_euph),
            address(_busd),
            amountEUPH,
            amountBUSD,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            lpUser,
            block.timestamp
        );
    }

    function _removeLiquidityPancake(address lpUser)
        private
        returns (uint256 amountEUPH, uint256 amountBUSD)
    {
        uint256 liquidity = _pancakeswapUserLPTokens[lpUser];
        _pancakeswapPair.approve(address(this), liquidity);
        _pancakeswapPair.approve(address(_pancakeswapRouter), liquidity);

        (amountEUPH, amountBUSD) = _pancakeswapRouter.removeLiquidity(
            address(_euph),
            address(_busd),
            liquidity,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            lpUser,
            addMinsTimestamp(block.timestamp, 30)
        );
    }

    function addMinsTimestamp(uint256 timestamp, uint256 mins) internal pure returns (uint256) {
        return timestamp + (mins * 60);
    }
}