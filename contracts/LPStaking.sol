// SPDX-License-Identifier: MIT
// Solidity 0.8.13 Optimization 200
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

//This smart contract's code was copied and adopted from the following source
//https://solidity-by-example.org/defi/staking-rewards/

contract LPStaking is Initializable, OwnableUpgradeable{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    uint64 constant PRECISION = 1e18;
    uint16 constant FIVE_MINUTES_IN_DAY = 288;

    struct StakeHolder {
        uint256 stakes; // total amount of stake holder stakes
        uint256 lastDepositedTime;
    }

    struct StakeHolderView {
        uint256 stakes;
        uint256 share;
        uint256 rewards;
        uint256 lastDepositedTime;
    }

    modifier contractActive() {
        require(_isContractActive(), "LP-Staking: The staking contract is not active for now");
        _;
    }

    modifier contractNotActive() {
        require(!_isContractActive(), "LP-Staking: The staking contract is paused");
        _;
    }

    modifier contractStarted() {
        require(stakingStarted == true, "LP-Staking: The staking contract has finished or not yet begun");
        _;
    }

    modifier contractNotStarted() {
        require(stakingStarted == false, "LP-Staking: The staking contract has already started");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "LP-Staking: Contract not allowed");
        require(msg.sender == tx.origin, "LP-Staking: Proxy contract not allowed");
        _;
    }

    modifier updateReward(address user) {
        rewardPerTokenStored = rewardPerToken();
        
        lastUpdateTime = _roundToFiveMins(block.timestamp);

        userRewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
        _;
    }

    IERC20Upgradeable private euphToken;
    IERC20Upgradeable private lpToken;

    bool private stakingStarted; // The boolean to check if the staking contract has been initialized and started the work process
    
    uint256 private distributedRewardsSnapshot;
    uint256 private rewardsPerFiveMins; // Amount of euphTokens that will be distributed among all users in 1 Day 
    uint256 public rewardSupply; // Initial amount of euphTokens allocated for Staking contract use
    uint256 public startTime; // Timestamp of the start day of the contract
    uint256 public endTime;
    uint256 public totalStakes; // Total number of stakes made by stake holders
    uint256 private stakeHoldersCount; // Total number of stake holders (users)
    uint256 public timeInPause; // Timestamp amount with no active stakes. If there were no stakes on a specific period, then no reward is distributed and the duration of contract is extended to paused amount

    mapping(address => StakeHolder) public stakeHoldersInfo;
    uint256 public lastUpdateTime; //Timestamp of last updatePool;
    uint256 public rewardPerTokenStored; // accBswPerShare variable in Biswap's MasterStaking contract
    bool private isContractActive;

    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public userRewards;

    function changeTokens(address _euphToken, address _lpToken) external onlyOwner contractNotStarted{
        _setToken(_euphToken);
        _setLPToken(_lpToken);
    }

    function initialize(uint256 _rewardSupply, uint256 _rewardPerFiveMins, address _euphTokenAddress, address _lpTokenAddress)
        external
        initializer
    {
        __Ownable_init();
        _setToken(_euphTokenAddress);
        _setLPToken(_lpTokenAddress);
        _setSupplyAndRewards(_rewardSupply, _rewardPerFiveMins);
    }

    function startStaking() external onlyOwner contractNotStarted {
        transferTokensToContract(rewardSupply);
        startTime = _roundToFiveMins(block.timestamp);
        lastUpdateTime = startTime;
        endTime = startTime + (((rewardSupply / rewardsPerFiveMins) * 1 days) / FIVE_MINUTES_IN_DAY);
        stakingStarted = true;
        isContractActive = true;
    }

    // <================================ END OF CONSTRUCTOR AND INITIALIZER ================================>

    // <================================ EVENTS ================================>
    event StakeCreated(address indexed stakeHolder, uint256 indexed stake);

    event RewardsWithdrawn(address indexed stakeHolder, uint256 indexed withdrawAmount);

    event UnStaked(address indexed stakeHolder, uint256 indexed withdrawAmount);

    event TokensTransferedToStakingBalance(address indexed sender, uint256 indexed amount);

    // <================================ EXTERNAL FUNCTIONS ================================>

    // <<<================================= GETTERS =================================>>>
    //THIS IS A CALL FUNCTION THAT RETURNS THE EXPECTED REWARD VALUE THE USER RECEIVES 
    function getUserReward(address user) public view returns(uint256) { 
        return earned(user);
    }

    function getTotalDistributedRewards() public view returns(uint256) {
        if(totalStakes == 0) {
            return distributedRewardsSnapshot;
        }
        if(block.timestamp >= endTime) {
            return ((endTime - (startTime + timeInPause)) / 5 minutes) * rewardsPerFiveMins;
        }
        return _fiveMinutesSinceTime(startTime + timeInPause) * rewardsPerFiveMins;
    }

    function getUserRewardPerFiveMins(address user) public view returns(uint256) { 
        return (stakeHoldersInfo[user].stakes * rewardsPerFiveMins) / totalStakes;
    }

    function getTotalStakes() external view returns(uint256) {
        return totalStakes;
    }

    // RETURNS TOTAL NUMBER OF STAKE HOLDERS
    function getStakeHoldersAmount() external view returns(uint256) {
        return stakeHoldersCount;
    }

    function isStakeHolder(address _stakeHolder) public view returns(bool) {
       return stakeHoldersInfo[_stakeHolder].stakes != 0;
    }

    function requestStakeHolderInfo(address _stakeHolder) external view returns(StakeHolderView memory) 
    {
        StakeHolderView memory stakeHolderView;
        StakeHolder memory stakeHolder = stakeHoldersInfo[_stakeHolder];
        stakeHolderView.rewards = getUserReward(_stakeHolder);
        stakeHolderView.stakes = stakeHolder.stakes;
        if(stakeHolderView.stakes != 0 && totalStakes != 0) stakeHolderView.share = (stakeHolder.stakes * PRECISION) / totalStakes;
        stakeHolderView.lastDepositedTime = stakeHolder.lastDepositedTime;
        
        return stakeHolderView;
    }
    
    // <<<================================= END OF GETTERS =================================>>>
    function rewardPerToken() public view returns (uint256) {
        if(_fiveMinutesSinceTime(lastUpdateTime) == 0) return rewardPerTokenStored;

        if (totalStakes <= 0) {
            return rewardPerTokenStored;
        }

        uint _rewardPerToken;
        uint _rewardsForPassedMinsValue = _rewardsForPassedMins();

        if(_rewardsForPassedMinsValue == 0) {
            return rewardPerTokenStored;
        }

        _rewardPerToken = rewardPerTokenStored + ((_rewardsForPassedMinsValue * PRECISION) / totalStakes);
        
        return _rewardPerToken;
    }

    function earned(address user) private view returns (uint) {
        uint256 _rewardPerToken = rewardPerToken();
        return
            ((stakeHoldersInfo[user].stakes *
                (_rewardPerToken - userRewardPerTokenPaid[user])) / PRECISION) +
            userRewards[user];
    }

    function transferTokensToContract(uint256 amount) public onlyOwner
    {
        address owner = _msgSender();
        euphToken.safeTransferFrom(owner, address(this), amount);
        emit TokensTransferedToStakingBalance(owner, amount);
    }

    function stake(uint256 _amount)
       external
       contractStarted
       contractActive
       notContract
       updateReward(msg.sender)
       returns (bool) 
    {
        address user = _msgSender();
        require(user != address(0), "LP-Staking: No zero address is allowed");
        require(_amount > 0, "LP-Staking: Nothing to stake");
        require(block.timestamp < endTime, "LP-Staking: Staking contract has already expired. Stake is not possible");

        if(!isStakeHolder(user))
        { 
            stakeHoldersCount += 1;
        }

        totalStakes += _amount;
        lpToken.safeTransferFrom(user, address(this), _amount);
        
        stakeHoldersInfo[user].stakes += _amount;
        stakeHoldersInfo[user].lastDepositedTime = block.timestamp;
        emit StakeCreated(user, _amount);
        return true;
    }

    function unStake(uint256 _amount)
        external
        contractStarted
        notContract
        updateReward(msg.sender)
        returns (bool)
    {
        address user = _msgSender();
        StakeHolder storage stakeHolder = stakeHoldersInfo[user];

        require(isStakeHolder(user), "LP-Staking: User is not a stake holder");
        require(_amount <= stakeHolder.stakes, "LP-Staking: Unstake amount exceeds user's actual stake value");
        require(_amount != 0, "LP-Staking: Cannot unstake 0 tokens");

        if(_amount == stakeHolder.stakes) {
            _removeStakeHolder(user);
        } else {
            stakeHolder.stakes -= _amount;
        }
        
        if(totalStakes - _amount == 0) {
            distributedRewardsSnapshot = getTotalDistributedRewards();
        }
        totalStakes -= _amount;
        
        lpToken.safeTransfer(msg.sender, _amount);

        emit UnStaked(user, _amount);
        return (true);
    }

    function unStakeWithRewards(uint256 _amount)
        external
        contractStarted
        notContract
        updateReward(msg.sender)
        returns (bool)
    {
        address user = _msgSender();
        StakeHolder storage stakeHolder = stakeHoldersInfo[user];

        require(isStakeHolder(user), "LP-Staking: User is not a stake holder");
        require(_amount <= stakeHolder.stakes, "LP-Staking: Unstake amount exceeds user's actual stake value");
        require(_amount != 0, "LP-Staking: Cannot unstake 0 tokens");
        uint reward = _withdrawUserRewards(user);

        if(_amount == stakeHolder.stakes) {
            _removeStakeHolder(user);
        } else {
            stakeHolder.stakes -= _amount;
        }
        
        if(totalStakes - _amount == 0) {
            distributedRewardsSnapshot = getTotalDistributedRewards();
        }
        totalStakes -= _amount;

        require(reward != 0, "LP-Staking: No rewards to withdraw");
        lpToken.safeTransfer(msg.sender, _amount);
        if(reward != 0) euphToken.safeTransfer(user, reward);

        emit UnStaked(user, _amount);
        return (true);
    }

    function withdrawRewards()
        external
        contractStarted
        notContract
        updateReward(msg.sender)
        returns (bool)
    {
        address user = _msgSender();

        uint reward = _withdrawUserRewards(user);

        require(reward != 0, "LP-Staking: No rewards to withdraw");

        euphToken.safeTransfer(user, reward);

        return true;
    }

    // ALLOWS TO WITHDRAW STUCK TOKENS. USED ONLY IN EMERGENCY SITUATIONS
    function recoverWrongToken(address _token, uint256 _amount) external onlyOwner notContract {
        require(_token != address(0), "LP-Staking: Token of zero address is not allowed");
        address owner = _msgSender();
        IERC20Upgradeable(_token).safeTransfer(owner, _amount);
    }

    function finalize() external onlyOwner notContract contractStarted contractNotActive {
        address owner = _msgSender();
        uint256 balanceEUPH = balanceOfContract();
        if(balanceEUPH > 0) euphToken.safeTransfer(owner, balanceEUPH);
        isContractActive = false;
    }

    // <================================ INTERNAL FUNCTIONS ================================>

    function balanceOfContract()
       internal
       view
       returns(uint256)
   {
       return euphToken.balanceOf(address(this));
   }

    // <================================ PRIVATE FUNCTIONS ================================>
    
    function _withdrawUserRewards(address user) private returns(uint256) {
        uint amountToWithdraw = userRewards[user];

        userRewards[user] = 0;

        return amountToWithdraw;
    }

    function _rewardsForPassedMins() private view returns(uint256) {
        uint256 passedFiveMinsAmount;

        if (block.timestamp > endTime && lastUpdateTime < endTime) {
            passedFiveMinsAmount = (endTime - lastUpdateTime) / 5 minutes;
        } else if (block.timestamp < endTime) {
            passedFiveMinsAmount = (block.timestamp - lastUpdateTime) / 5 minutes;
        }

        return rewardsPerFiveMins * passedFiveMinsAmount;
    }

    function _removeStakeHolder(address _stakeHolder) private contractStarted {
        delete stakeHoldersInfo[_stakeHolder];
        
        stakeHoldersCount -= 1;
   }

    function _setSupplyAndRewards(uint256 _rewardSupply, uint256 _rewardsPerFiveMins) private {
        require(_rewardSupply > 0 && _rewardsPerFiveMins > 0, "LP-Staking: Reward supply must be higher than 0");
        rewardSupply = _rewardSupply;
        rewardsPerFiveMins = _rewardsPerFiveMins;
    }

    function _setToken(address newTokenAddress) private {
        require(
            address(euphToken) != newTokenAddress,
            "LP-Staking: Cannot change euphToken of same address"
        );
        euphToken = IERC20Upgradeable(newTokenAddress);
    }

    function _setLPToken(address newTokenAddress) private {
        require(
            address(lpToken) != newTokenAddress,
            "LP-Staking: Cannot change euphToken of same address"
        );
        lpToken = IERC20Upgradeable(newTokenAddress);
    }

    function _pauseSinceTime(uint256 _timestamp) private view returns (uint256) {
        return _timestamp >= startTime ? block.timestamp - _timestamp : 0;
    }

    function _fiveMinutesSinceTime(uint256 _timestamp) private view returns (uint256) {
        return _timestamp >= startTime ? (block.timestamp - _timestamp) / 5 minutes : 0;
    }

    function _roundToFiveMins(uint256 _timestamp) private pure returns (uint256) {
        return _timestamp - (_timestamp % 5 minutes);
    }

    function _isContractActive() private returns(bool) {
        require(block.timestamp >= lastUpdateTime, "LP-Staking: Provided block.timestamp value has been modified");
        if(totalStakes == 0) {
            uint256 elapsedTimeInPause = _roundToFiveMins(_pauseSinceTime(lastUpdateTime));
            timeInPause += elapsedTimeInPause;
            endTime += elapsedTimeInPause;
            lastUpdateTime = _roundToFiveMins(block.timestamp);
        }
        return isContractActive; //block.timestamp - timeInPause >= contractDurationInDays * 1 days + startTime;
    }

    function _isContract(address addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}