// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract BettingLiquidityPool is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    uint64 constant PRECISION = 1e12;
    uint16 constant FIVE_MINUTES_IN_DAY = 288;
    uint256 public constant MAX_WITHDRAW_FEE = 200; // 2%
    uint256 public constant MAX_WITHDRAW_FEE_PERIOD = 5 days; // 5 days

    struct LiquidityProvider {
        uint256 liquidity;
        uint256 lastDepositedTime;
    }

    struct LiquidityProviderForView {
        uint256 rewards; 
        uint256 liquidity; 
        uint256 share;
        uint256 lastDepositedTime;
    }

    struct Fees {
        uint16 leftoversFee;
        uint16 treasuryFee;
    }

    modifier isAuthorizedAddress(address addr) {
        require(authorizedContracts[addr], "This contract address is not authorized");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    modifier updateReward(address user) {
        userRewards[user] = earned(user);
        userRewardPerTokenPaid[user] = rewardPerTokenStored;
        
        _;
    }

    IERC20Upgradeable private euphToken;
    
    address public treasury; // Address where withdraw fee will be sent to

    uint256 public totalLiquidity; // Total number of liquidity added by lp provider
    uint256 public lpProvidersCount; // Total number of lp providers (users)
    
    mapping(address => LiquidityProvider) public lpProvidersInfo;
    uint256 public lastUpdateTime; //Timestamp of last updatePool;
    uint256 public rewardPerTokenStored; // accBswPerShare variable in Biswap's MasterStaking contract
    bool public isContractActive;

    mapping(address => uint) public userRewardPerTokenPaid;
    mapping(address => uint) public userRewards;
    mapping(address => bool) private authorizedContracts;

    Fees public fees;
    uint256 public lentTokensAmount;
    uint256 public safetyPool;
    uint256 public treasuryPool;

    function changeToken(address newTokenAddress) external onlyOwner {
        _setToken(newTokenAddress);
    }

    function changeTreasury(address newTreasuryAddress) external onlyOwner {
        _setTreasury(newTreasuryAddress);
    }

    function initialize(address _euphTokenAddress, address _treasuryAddress)
        external
        initializer
    {
        __Ownable_init();
        __Pausable_init();
        _setToken(_euphTokenAddress);
        _setTreasury(_treasuryAddress);

        fees = Fees({
            leftoversFee: 2000,
            treasuryFee: 2000
        });
    }

    // <================================ END OF CONSTRUCTOR AND INITIALIZER ================================>

    // <================================ EVENTS ================================>
    event LiquidityAdded(address indexed lpProvider, uint256 indexed liquidity);

    event RewardsWithdrawn(address indexed lpProvider, uint256 indexed withdrawAmount);

    event LiquidityRemoved(address indexed lpProvider, uint256 indexed withdrawAmount);

    event TokensTransferedToLiquidityPool(address indexed sender, uint256 indexed amount);

    // <================================ EXTERNAL FUNCTIONS ================================>

    // <<<================================= GETTERS =================================>>>
    //THIS IS A CALL FUNCTION THAT RETURNS THE EXPECTED REWARD VALUE THE USER RECEIVES 
    function getUserReward(address user) public view returns(uint256) {
        return earned(user);
    }

    function getUsersTotalLiquidity() external view returns(uint256) {
        return totalLiquidity;
    }

    function getTotalLiquidity() external view returns(uint256) {
        return _liquidityBalance();
    }

    // RETURNS TOTAL NUMBER OF LP PROVIDERS
    function getLiquidityProvidersAmount() external view returns(uint256) {
        return lpProvidersCount;
    }

    function getLpProviderShare(address _lpProvider) public view returns(uint256) {
        return totalLiquidity > 0 ? (lpProvidersInfo[_lpProvider].liquidity * PRECISION) / totalLiquidity : 0;
    }

    function isLiquidityProvider(address _lpProvider) public view returns(bool) {
       return lpProvidersInfo[_lpProvider].liquidity != 0;
    }

    function requestLpProviderInfo(address _lpProvider) external view returns(
        LiquidityProviderForView memory
    ) 
    {
        LiquidityProvider memory liquidityProvider = lpProvidersInfo[_lpProvider];
        LiquidityProviderForView memory liquidityProviderForView;
        
        liquidityProviderForView.rewards = getUserReward(_lpProvider);
        liquidityProviderForView.liquidity = liquidityProvider.liquidity;
        liquidityProviderForView.share = getLpProviderShare(_lpProvider);
        liquidityProviderForView.lastDepositedTime = liquidityProvider.lastDepositedTime;

        return liquidityProviderForView;
    }
    
    // <<<================================= END OF GETTERS =================================>>>

    function addAuthorizedContract(address _contract) external onlyOwner {
        require(_isContract(_contract), "only contract address is allowed");
        authorizedContracts[_contract] = true;
    }

    function removeAuthorizedContract(address _contract) external isAuthorizedAddress(_contract) onlyOwner {
        delete authorizedContracts[_contract];
    }

    function injectRewards(uint256 _amount, uint256 _leftovers) whenNotPaused external {
        if(_amount == 0) return;
        
        uint256 _lentTokensAmount = lentTokensAmount;
        uint treasurySum = (_amount * fees.treasuryFee) / 10000;
        uint leftoversSum = (_amount * fees.leftoversFee) / 10000;
        uint rewardsSum = _amount - treasurySum - leftoversSum;
        if(_leftovers != 0) leftoversSum += _leftovers;

        uint256 totalLiquidityPool = safetyPool + leftoversSum;

        if(totalLiquidityPool >= _lentTokensAmount) {
            totalLiquidityPool -= lentTokensAmount;
            lentTokensAmount = 0;
        }

        treasuryPool += treasurySum;
        safetyPool = totalLiquidityPool;
        rewardPerTokenStored = rewardPerToken(rewardsSum);
        
        euphToken.safeTransferFrom(msg.sender, address(this), _amount + _leftovers);
        
        lastUpdateTime = block.timestamp;
    }

    function injectToSafetyPool(uint256 _amount) external whenNotPaused onlyOwner {
        require(_amount > 0, "BLP: Inject amount has to be more than zero");
        safetyPool += _amount;
        euphToken.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function lendTokens(uint256 amount) public whenNotPaused isAuthorizedAddress(msg.sender) returns (bool) {
        address contractAddress = _msgSender();
        if(amount > _liquidityBalance()) {
            return false;
        }
        lentTokensAmount += amount;
        euphToken.safeTransfer(contractAddress, amount);
        return true;
    }

    function rewardPerToken(uint reward) public view returns (uint) {
        if(paused()) return rewardPerTokenStored;

        if (totalLiquidity <= 0) {
            return rewardPerTokenStored;
        }

        uint _rewardPerToken;

        _rewardPerToken = rewardPerTokenStored + ((reward * PRECISION) / totalLiquidity);
        
        return _rewardPerToken;
    }

    function earned(address user) public view returns (uint) {
        uint256 _rewardPerToken = rewardPerTokenStored;
        return
            ((lpProvidersInfo[user].liquidity *
                (_rewardPerToken - userRewardPerTokenPaid[user])) / PRECISION) +
            userRewards[user];
    }

    function transferTokensToContract(uint256 amount) public onlyOwner
    {
        address owner = _msgSender();
        euphToken.safeTransferFrom(owner, address(this), amount);
        emit TokensTransferedToLiquidityPool(owner, amount);
    }

    function addLiquidity(uint256 _amount)
       external
       whenNotPaused
       notContract
       updateReward(msg.sender)
       returns (bool) 
    {
        address user = _msgSender();
        require(user != address(0), "Staking: No zero address is allowed");
        require(_amount > 0, "Staking: No liquidity to be added");
        LiquidityProvider storage liquidityProvider = lpProvidersInfo[user];

        if(!isLiquidityProvider(user))
        { 
            lpProvidersCount += 1;
        }
        
        totalLiquidity += _amount;
        euphToken.safeTransferFrom(user, address(this), _amount);
        
        liquidityProvider.liquidity += _amount;
        liquidityProvider.lastDepositedTime = block.timestamp;

        emit LiquidityAdded(user, _amount);
        return true;
    }

    function removeLiquidity(uint256 _amount)
        external
        notContract
        updateReward(msg.sender)
        returns (bool)
    {
        address user = _msgSender();
        LiquidityProvider storage liquidityProvider = lpProvidersInfo[user];

        require(_amount <= liquidityProvider.liquidity, "Amount for removal exceeds user's actual deposited liquidity value");
        require(_liquidityBalance() >= _amount, "There is not enough tokens in Pool to be withdrawn for now. Wait, while the Pool is being replenished");

        if(_amount == liquidityProvider.liquidity) {
            _removeLiquidityProvder(user);
        } else {
            liquidityProvider.liquidity -= _amount;
        }
        
        totalLiquidity -= _amount;
        
        euphToken.safeTransfer(msg.sender, _amount);

        emit LiquidityRemoved(user, _amount);
        return true;
    }

    function withdrawRewards()
        external
        notContract
        updateReward(msg.sender)
        returns (bool)
    {
        require(!paused(), "Staking: BLP contract is in pause");
        address user = _msgSender();

        uint reward = _withdrawUserRewards(user);
        
        euphToken.safeTransfer(user, reward);

        emit RewardsWithdrawn(user, reward);
        return true;
    }

    // ALLOWS TO WITHDRAW STUCK TOKENS. USED ONLY IN EMERGENCY SITUATIONS
    function recoverWrongToken(address _token, uint256 _amount) external onlyOwner notContract {
        require(_token != address(0), "Staking: Token of zero address is not allowed");
        address owner = _msgSender();
        IERC20Upgradeable(_token).safeTransfer(owner, _amount);
    } 

    function finalize() external onlyOwner notContract {
        address owner = _msgSender();
        uint256 balanceEUPH = balanceOfContract();
        if(balanceEUPH > 0) euphToken.safeTransfer(owner, balanceEUPH);
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
        uint amountToWithdraw;
        amountToWithdraw = userRewards[user];
        userRewards[user] = 0;
        return amountToWithdraw;
    }

    function _removeLiquidityProvder(address _lpProvider) private  {
        delete lpProvidersInfo[_lpProvider];
        
        lpProvidersCount -= 1;
    }

    function _setToken(address newTokenAddress) private {
        require(
            address(euphToken) != newTokenAddress,
            "Staking: Cannot change euphToken of same address"
        );
        euphToken = IERC20Upgradeable(newTokenAddress);
    }

    function _setTreasury(address newTreasuryAddress) private {
        require(
            address(treasury) != newTreasuryAddress,
            "Staking: Cannot change treasuiry of same address"
        );
        treasury = address(newTreasuryAddress);
    }

    function _monthsSinceDate(uint256 _timestamp) private view returns(uint256){
        return block.timestamp > _timestamp ? (block.timestamp - _timestamp) / 2629746 : 0; //2629746 is 30.436875 days
    }

    function _isContract(address addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function _liquidityBalance() private view returns(uint256) {
        return totalLiquidity + safetyPool - lentTokensAmount;
    }
}