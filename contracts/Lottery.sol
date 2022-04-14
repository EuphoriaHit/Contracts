// SPDX-License-Identifier: MIT
// Solidity 0.8.13 Optimization 100
pragma solidity ^0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface IPriceOracle {
    struct Observation {
        uint256 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    function pairObservations(address pairAddress)
        external
        view
        returns (Observation memory);

    function update(address tokenA, address tokenB) external returns (bool);

    function consult(
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) external view returns (uint256);

    function consultAndUpdate(
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) external returns (uint256);
}

/** @title Euphoria Lottery.
 * @notice It is a contract for a lottery system using
 * randomness provided externally.
 */
contract EuphoriaLottery is
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 public constant MIN_DISCOUNT_DIVISOR = 300;
    uint256 public constant MIN_LENGTH_LOTTERY = 1 hours - 5 minutes; // 1 hour
    uint256 public constant MAX_LENGTH_LOTTERY = 31 days + 5 minutes; // 31 days
    uint256 public constant MAX_TREASURY_SHARE = 3000; // 30%
    uint256 public constant MAX_COMPETITION_SHARE = 1500; // 15%

    enum Status {
        Pending,
        Open,
        Close,
        Claimable
    }

    struct Lottery {
        bool custom;
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 drawnTime;
        uint256 priceTicketInEUPH;
        uint256 priceTicketInBUSD;
        uint256 maxNumberTicketsPerBuy;
        uint256 discountDivisor;
        uint256 treasuryShare;
        uint256 competitionShare;
        uint256[6] rewardsBreakdown; // 0: 1 matching number // 5: 6 matching numbers
        uint256[6] euphPerBracket;
        uint256[6] countWinnersPerBracket;
        uint256 firstTicketId;
        uint256 firstTicketIdNextLottery;
        uint256 amountCollectedInEUPH;
        uint256 amountInjectedInEUPH;
        uint32 finalNumber;
    }

    struct Ticket {
        uint32 number;
        address owner;
    }

    struct TicketsRange {
        uint256 startTicketId;
        uint256 endTicketId;
    }

    // This struct is used in call methods to return JSON formatted result
    struct TicketsView {
        uint256[] ticketIds;
        uint32[] ticketNumbers;
        bool[] ticketStatuses;
    }

    struct UserTicketsView {
        uint256[] ticketIds;
        uint32[] ticketNumbers;
        bool[] ticketStatuses;
        uint256 boughtTicketsAmount;
    }

    struct UserWinningTicketsView {
        uint256[] ticketIds;
        uint32[] ticketBrackets;
    }

    struct PublicAddresses {
        address injectorAddress;
        address operatorAddress;
        address treasuryAddress;
        address busdTokenAddress;
        address euphTokenAddress;
    }

    IERC20Upgradeable private euphToken;
    IPriceOracle private priceOracle;

    // Mapping are cheaper than arrays

    // Keep track of user ticket ids for a given lotteryId
    // To save gas, contract will save only first and last ticket ids of bought tickets in one transaction
    // If user buys 10 tickets of ids in a range between 4 and 13, then _userMultipleTicketIdsPerLotteryId[user][lotteryId][index].startTicketId will equal to 4
    // and _userMultipleTicketIdsPerLotteryId[user][lotteryId][index].endTicketId will be 13 respectively
    // This way contract will write only 2 uint256 values instead of 10
    // In case when user buys one ticket, then all single ticketIds are being recorded in _userSingleTicketIdsPerLotteryId mapping
    mapping(address => mapping(uint256 => uint256[])) private _userSingleTicketIdsPerLotteryId; //
    mapping(address => mapping(uint256 => TicketsRange[])) private _userMultipleTicketIdsPerLotteryId;
    
    // Keep track of lottery ids where user has participated in but hasn't withdrawn tickets rewards
    mapping(address => uint256[]) private _userLotteryIds;
    mapping(address => uint256) private _userLotteryBalance;

    // Keep track of users bought tickets per lottery game
    mapping(address => mapping(uint => uint)) private _userTicketsAmountPerLotteryId;
    
    // Keep track of lottery games and tickets
    mapping(uint256 => Lottery) private _lotteries;
    mapping(uint256 => Ticket) private _tickets;

    // Bracket calculator is used for verifying claims for ticket prizes
    mapping(uint32 => uint32) private _bracketCalculator;

    // Contract important addresses
    address private injectorAddress;
    address private operatorAddress;
    address private treasuryAddress;
    address private busdTokenAddress;
    address private euphTokenAddress;

    // Logic variables
    uint256 private currentLotteryId;
    uint256 public currentTicketId;

    uint256 private maxTicketPriceInEUPH;
    uint256 private minTicketPriceInEUPH;

    uint256 private pendingInjectionNextLottery;
    uint256 public lastPriceOracleUpdateTime;
    uint256 private competitionBalance;
    uint256 private collectedTicketsAmountInEUPH;

    // Default lottery values
    uint256 private defaultTicketPriceInBUSD;
    uint256 private defaultMaxTicketsNumberPerBuy;
    uint256 private defaultDiscountDivisor;
    uint256 private defaultTreasuryShare;
    uint256 private defaultCompetitionShare;
    uint256 private defaultPriceUpdateInterval;
    uint256[6] private defaultRewardsBreakdown;

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    modifier onlyOwnerOrInjector() {
        require(
            (msg.sender == owner()) || (msg.sender == injectorAddress),
            "Not owner or injector"
        );
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(
            (msg.sender == owner()) || (msg.sender == operatorAddress),
            "Not owner or operator"
        );
        _;
    }

    event AdminTokenRecovery(address token, uint256 amount);
    event LotteryInjection(uint256 indexed lotteryId, uint256 injectedAmount);
    event LotteryOpen(
        uint256 indexed lotteryId,
        uint256 startTime,
        uint256 endTime,
        uint256 priceTicketInEUPH,
        uint256 firstTicketId,
        uint256 injectedAmount
    );
    event LotteryNumberDrawn(
        uint256 indexed lotteryId,
        uint256 finalNumber,
        uint256 countWinningTickets
    );
    event NewOperatorAndTreasuryAndInjectorAddresses(
        address operator,
        address treasury,
        address injector
    );
    event NewDefaultValues(
        uint256 defaultTicketPriceInBUSD,
        uint256 defaultMaxTicketsNumberPerBuy,
        uint256 defaultDiscountDivisor,
        uint256 defaultTreasuryShare,
        uint256 defaultCompetitionShare,
        uint256 defaultPriceUpdateInterval,
        uint256[6] defaultRewardsBreakdown
    );
    event TicketsPurchase(
        address indexed buyer,
        uint256 indexed lotteryId,
        uint256 numberTickets
    );
    event WithdrawLotteryBalance(
        address indexed claimer,
        uint256 amount
    );
    event DistributeCompetitionRewards(
        uint256 indexed timestamp,
        uint256 amount
    );

    function initialize(
        address _euphTokenAddress,
        address _busdTokenAddress,
        address _priceOracleAddress,
        address _operatorAddress,
        address _injectorAddress,
        address _treasuryAddress
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        euphToken = IERC20Upgradeable(_euphTokenAddress);
        euphTokenAddress = _euphTokenAddress;
        busdTokenAddress = _busdTokenAddress;
        priceOracle = IPriceOracle(_priceOracleAddress);
        operatorAddress = _operatorAddress;
        injectorAddress = _injectorAddress;
        treasuryAddress = _treasuryAddress;

        maxTicketPriceInEUPH = 1e12;
        minTicketPriceInEUPH = 1e3;

        // Setting the default values
        defaultRewardsBreakdown = [350, 500, 850, 1800, 2500, 4000];
        defaultTicketPriceInBUSD = 1e18;
        defaultMaxTicketsNumberPerBuy = 500;
        defaultDiscountDivisor = 10000;
        defaultTreasuryShare = 200;
        defaultCompetitionShare = 500;
        defaultPriceUpdateInterval = 1 hours;

        _bracketCalculator[0] = 1;
        _bracketCalculator[1] = 11;
        _bracketCalculator[2] = 111;
        _bracketCalculator[3] = 1111;
        _bracketCalculator[4] = 11111;
        _bracketCalculator[5] = 111111;
    }

    // <================================ USER CALLABLE METHODS ================================>

    /**
     * @notice Buy tickets for the current lottery
     * @param _lotteryId: lotteryId
     * @param _ticketNumbers: array of ticket numbers between 1,000,000 and 1,999,999
     * @param _winningLotteryIds: Id of lottery games where winningTicketIds and winningBrackets relate to
     * @param _winningTicketIds: Id of tickets where to collect rewards from
     * @param _winningBrackets: winning brackets of tickets
     * @param spendUserBalance: Buy tickets using user balance or not
     * @dev Callable by users
     */
     function buyTickets(uint256 _lotteryId, 
        uint32[] calldata _ticketNumbers, 
        uint256[] calldata _winningLotteryIds,
        uint256[][] calldata _winningTicketIds,
        uint32[][] calldata _winningBrackets,
        bool spendUserBalance
    )
        external
        notContract
        nonReentrant
    {
        uint256 ticketsPriceInEuph = _buyTicketsInitialize(_lotteryId, _ticketNumbers.length);
        uint256 userPendingLotteryBalance;
        uint256 userTotalLotteryBalance = _userLotteryBalance[msg.sender];
        uint256 amountEuphToTransfer;

        if(_winningLotteryIds.length != 0) {
            (userPendingLotteryBalance,) = _claimAllTickets(_winningLotteryIds, _winningTicketIds, _winningBrackets);
            userTotalLotteryBalance += userPendingLotteryBalance;
        }

        if(spendUserBalance) {
            if(ticketsPriceInEuph >= userTotalLotteryBalance) {
                delete _userLotteryBalance[msg.sender];
                amountEuphToTransfer = ticketsPriceInEuph - userTotalLotteryBalance;
            } else {
                _userLotteryBalance[msg.sender] = userTotalLotteryBalance - ticketsPriceInEuph;
                amountEuphToTransfer = 0;
            }
        } else {
            if(userPendingLotteryBalance != 0) _userLotteryBalance[msg.sender] += userPendingLotteryBalance;
            amountEuphToTransfer = ticketsPriceInEuph;
        }
        // Transfer euph tokens to this contract

        if(amountEuphToTransfer != 0){
            euphToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                amountEuphToTransfer
            );
        }

        _buyTicketsFinalize(ticketsPriceInEuph, _lotteryId, _ticketNumbers);

        emit TicketsPurchase(msg.sender, _lotteryId, _ticketNumbers.length);
    }

    function withdrawLotteryBalance(
        uint256 _withdrawAmount,
        uint256[] calldata _winningLotteryIds,
        uint256[][] calldata _winningTicketIds,
        uint32[][] calldata _winningBrackets
    ) external notContract nonReentrant {
        _withdrawLotteryBalance(
            _withdrawAmount,
            _winningLotteryIds,
            _winningTicketIds,
            _winningBrackets
        );
    }

    /**
     * @notice Withdraw lottery balance
     * @param _withdrawAmount: withdraw amount
     * @dev Callable by users
     */
    function withdrawLotteryBalance(
        uint256 _withdrawAmount
    ) external notContract nonReentrant {
        _withdrawLotteryBalance(
            _withdrawAmount,
            new uint256[](0),
            new uint256[][](0),
            new uint32[][](0)
        );
    }

    // <================================ OPERATOR METHODS ================================>

    /**
     * @notice Close lottery and Draw Final number
     * @param _lotteryId: lottery id
     * @param _finalNumber: random number obtained from Random.org
     * @param _euphPerBracket: distribution of winnings by bracket
     * @param _ticketsCountPerBracket: total number of tickets in each bracket
     * @param _autoInjection: reinjects funds into next lottery (vs. withdrawing all)
     * @dev Callable by owner or operator
     */
    function closeLotteryAndDrawFinalNumber(
        uint256 _lotteryId,
        uint32 _finalNumber,
        uint256[6] calldata _euphPerBracket,
        uint256[6] calldata _ticketsCountPerBracket,
        bool _autoInjection
    ) external onlyOwnerOrOperator nonReentrant {
        bool isCustomLottery = _lotteries[_lotteryId].custom;
        uint[6] memory rewardsBreakdown = isCustomLottery ? _lotteries[_lotteryId].rewardsBreakdown : defaultRewardsBreakdown;

        require(
            _lotteries[_lotteryId].status == Status.Open,
            "Lottery not open"
        );
        require(
            block.timestamp > _lotteries[_lotteryId].endTime,
            "Lottery not over"
        );
        _lotteries[_lotteryId].firstTicketIdNextLottery = currentTicketId;

        require(
            _euphPerBracket.length == 6,
            "Wrong euphPerBracket array size!"
        );
        require(
            _ticketsCountPerBracket.length == 6,
            "Wrong countTicketsPerBracket array size!"
        );

        //Withdraw burn, referrals and competitions pool
        uint256 amountToShareToWinners = _withdrawTreasuryAndCompetition(
            _lotteryId
        ) + _lotteries[_lotteryId].amountInjectedInEUPH;

        uint256 ticketsCountPerBrackets = 0;
        uint256 euphSumPerBrackets = 0;
        for (uint256 i = 0; i < 6; i++) {
            uint256 winningPoolPerBracket = _euphPerBracket[i] *
                _ticketsCountPerBracket[i];
            ticketsCountPerBrackets += _ticketsCountPerBracket[i];

            if (_ticketsCountPerBracket[i] > 0) {
                require(
                    winningPoolPerBracket <=
                        (rewardsBreakdown[i] *
                            amountToShareToWinners) /
                            10000,
                    "Wrong amount on bracket"
                );
            }
            euphSumPerBrackets += winningPoolPerBracket;
        }
        require(
            euphSumPerBrackets <= amountToShareToWinners,
            "Wrong brackets Total amount"
        );

        _lotteries[_lotteryId].euphPerBracket = _euphPerBracket;
        _lotteries[_lotteryId].countWinnersPerBracket = _ticketsCountPerBracket;

        // Update internal statuses for lottery
        _lotteries[_lotteryId].finalNumber = _finalNumber;
        _lotteries[_lotteryId].status = Status.Claimable;
        _lotteries[_lotteryId].drawnTime = block.timestamp;

        // Transfer not winning EUPH to treasury address if _autoInjection is false
        if (_autoInjection) {
            pendingInjectionNextLottery =
                amountToShareToWinners -
                euphSumPerBrackets;
        } else {
            euphToken.safeTransfer(
                treasuryAddress,
                amountToShareToWinners - euphSumPerBrackets
            );
        }

        emit LotteryNumberDrawn(
            currentLotteryId,
            _finalNumber,
            ticketsCountPerBrackets
        );
    }

    /**
     * @notice Inject funds
     * @param _lotteryId: lottery id
     * @param _amount: amount to inject in EUPH token
     * @dev Callable by owner or injector address
     */
    function injectFunds(uint256 _lotteryId, uint256 _amount)
        external
        onlyOwnerOrInjector
    {
        require(
            _lotteries[_lotteryId].status == Status.Open,
            "Lottery not open"
        );

        euphToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        _lotteries[_lotteryId].amountCollectedInEUPH += _amount;

        emit LotteryInjection(_lotteryId, _amount);
    }

    function distributeCompetitionRewards (address[] calldata users, uint256[] calldata rewards)
        external
        onlyOwnerOrOperator
    {
        require(users.length == rewards.length, "Users and rewards amount must be equal");
        uint256 totalRewards;

        for(uint256 i = 0; i < users.length; i++) {
            _userLotteryBalance[users[i]] += rewards[i];
            totalRewards += rewards[i];
        }

        require(totalRewards <= competitionBalance, "Provided rewards exceed existing competition amount");
        delete competitionBalance;
        delete collectedTicketsAmountInEUPH;

        emit DistributeCompetitionRewards(block.timestamp, totalRewards);
    }

    function withdrawCompetitionBalance ()
        external
        onlyOwner
    {
        require(competitionBalance > 0, "Nothing to withdraw");
        euphToken.safeTransfer(_msgSender(), competitionBalance);
    }

    /**
     * @notice Start the lottery
     * @dev Callable by operator
     * @param _custom: custom lottery or default
     * @param _endTime: endTime of the lottery
     * @param _priceTicketInBUSD: price of a ticket in EUPH
     * @param _discountDivisor: the divisor to calculate the discount magnitude for bulks
     * @param _maxNumberTicketsPerBuy: max number of tickets to be claimed
     * @param _rewardsBreakdown: breakdown of rewards per bracket (must sum to 10,000)
     * @param _treasuryShare: treasury fee (10,000 = 100%, 100 = 1%)
     * @param _competitionShare: competition fee (10,000 = 100%, 100 = 1%)
     * @dev Callable by owner or operator.
     */
    function startLottery(
        bool _custom,
        uint256 _endTime,
        uint256 _priceTicketInBUSD,
        uint256 _discountDivisor,
        uint256 _maxNumberTicketsPerBuy,
        uint256[6] calldata _rewardsBreakdown,
        uint256 _treasuryShare,
        uint256 _competitionShare
    ) external onlyOwnerOrOperator {
        require(
            (currentLotteryId == 0) ||
                (_lotteries[currentLotteryId].status == Status.Claimable),
            "Not time to start lottery"
        );

        require( _endTime > block.timestamp, "Lottery length outside of range");

        require(
            ((_endTime - block.timestamp) > MIN_LENGTH_LOTTERY) &&
                ((_endTime - block.timestamp) < MAX_LENGTH_LOTTERY),
            "Lottery length outside of range"
        );

        uint256 _priceTicketInEUPH = priceOracle.consult(busdTokenAddress, _priceTicketInBUSD, euphTokenAddress);

        require(
            (_priceTicketInEUPH >= minTicketPriceInEUPH) &&
                (_priceTicketInEUPH <= maxTicketPriceInEUPH),
            "Outside of limits"
        );

        require(
            _discountDivisor >= MIN_DISCOUNT_DIVISOR,
            "Discount divisor too low"
        );
        require(_treasuryShare <= MAX_TREASURY_SHARE, "Treasury fee too high");
        require(
            _competitionShare <= MAX_COMPETITION_SHARE,
            "Competition fee too high"
        );

        require(
            (_rewardsBreakdown[0] +
                _rewardsBreakdown[1] +
                _rewardsBreakdown[2] +
                _rewardsBreakdown[3] +
                _rewardsBreakdown[4] +
                _rewardsBreakdown[5]) == 10000,
            "Rewards must equal 10000"
        );

        currentLotteryId++;

        Lottery memory tempLottery = Lottery({
            custom: _custom,
            status: Status.Open,
            startTime: block.timestamp,
            endTime: _endTime,
            drawnTime: 0,
            priceTicketInEUPH: _priceTicketInEUPH,
            priceTicketInBUSD: _priceTicketInBUSD,
            discountDivisor: _discountDivisor,
            maxNumberTicketsPerBuy: _maxNumberTicketsPerBuy,
            treasuryShare: _treasuryShare,
            competitionShare: _competitionShare,
            rewardsBreakdown: _rewardsBreakdown,
            euphPerBracket: [
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0)
            ],
            countWinnersPerBracket: [
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0)
            ],
            firstTicketId: currentTicketId,
            firstTicketIdNextLottery: currentTicketId,
            amountCollectedInEUPH: 0,
            amountInjectedInEUPH: pendingInjectionNextLottery,
            finalNumber: 0
        });

        if(!_custom) {
            tempLottery.priceTicketInBUSD = 0;
            tempLottery.discountDivisor = 0;
            tempLottery.maxNumberTicketsPerBuy = 0;
            tempLottery.treasuryShare = 0;
            tempLottery.competitionShare = 0;
            tempLottery.rewardsBreakdown = [
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0),
                uint256(0)
            ];
        }

        _lotteries[currentLotteryId] = tempLottery;

        emit LotteryOpen(
            currentLotteryId,
            block.timestamp,
            _endTime,
            _priceTicketInEUPH,
            currentTicketId,
            pendingInjectionNextLottery
        );

        pendingInjectionNextLottery = 0;
    }

    // <================================ ADMIN METHODS ================================>

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of token amount to withdraw
     * @dev Only callable by owner.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
        external
        onlyOwner
    {
        IERC20Upgradeable(_tokenAddress).safeTransfer(
            address(msg.sender),
            _tokenAmount
        );

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /**
     * @notice Set EUPH price ticket upper/lower limit
     * @dev Only callable by owner
     * @param _minTicketPriceInEUPH: minimum price of a ticket in EUPH
     * @param _maxTicketPriceInEUPH: maximum price of a ticket in EUPH
     * @dev Only callable by owner.
     */
    function setMinAndMaxTicketPriceInEUPH(
        uint256 _minTicketPriceInEUPH,
        uint256 _maxTicketPriceInEUPH
    ) external onlyOwner {
        require(
            _minTicketPriceInEUPH <= _maxTicketPriceInEUPH,
            "minPrice must be < maxPrice"
        );

        minTicketPriceInEUPH = _minTicketPriceInEUPH;
        maxTicketPriceInEUPH = _maxTicketPriceInEUPH;
    }

    /**
     * @notice Get reward from winning tickets
     * @param _defaultTicketPriceInBUSD: Default value for one ticket in BUSD token
     * @param _defaultMaxTicketsNumberPerBuy: Default value of max tickets per one buy transaction
     * @param _defaultDiscountDivisor: Default discount divisor value
     * @param _defaultTreasuryShare: Default treasury address fee share
     * @param _defaultCompetitionShare: Default Competition And Ref address fee share
     * @param _defaultPriceUpdateInterval: default price update interval
     * @param _defaultRewardsBreakdown: default value of Rewards breakdown
     * @dev Only callable by owner.
     */
    function setDefaultValues(
        uint256 _defaultTicketPriceInBUSD,
        uint256 _defaultMaxTicketsNumberPerBuy,
        uint256 _defaultDiscountDivisor,
        uint256 _defaultTreasuryShare,
        uint256 _defaultCompetitionShare,
        uint256 _defaultPriceUpdateInterval,
        uint256[6] calldata _defaultRewardsBreakdown
    ) external onlyOwner {
        if(_defaultTicketPriceInBUSD != 0) defaultTicketPriceInBUSD = _defaultTicketPriceInBUSD;
        if(_defaultMaxTicketsNumberPerBuy != 0) defaultMaxTicketsNumberPerBuy = _defaultMaxTicketsNumberPerBuy;
        if(_defaultDiscountDivisor != 0) defaultDiscountDivisor = _defaultDiscountDivisor;
        if(_defaultTreasuryShare != 0) defaultTreasuryShare = _defaultTreasuryShare;
        if(_defaultCompetitionShare != 0) defaultCompetitionShare = _defaultCompetitionShare;
        if(_defaultPriceUpdateInterval != 0) defaultPriceUpdateInterval = _defaultPriceUpdateInterval;
        if(_defaultRewardsBreakdown[0] != 0) defaultRewardsBreakdown = _defaultRewardsBreakdown;

        emit NewDefaultValues(
            _defaultTicketPriceInBUSD,
            _defaultMaxTicketsNumberPerBuy,
            _defaultDiscountDivisor,
            _defaultTreasuryShare,
            _defaultCompetitionShare,
            _defaultPriceUpdateInterval,
            _defaultRewardsBreakdown
        );
    }

    /**
     * @notice Set operator, treasury, and injector addresses
     * @dev Only callable by owner
     * @param _operatorAddress: address of the operator
     * @param _treasuryAddress: address of the treasury
     * @param _injectorAddress: address of the injector
     * @dev Only callable by owner.
     */
    function setOperatorAndTreasuryAndInjectorAddresses(
        address _operatorAddress,
        address _treasuryAddress,
        address _injectorAddress
    ) external onlyOwner {
        if(_operatorAddress != address(0)) operatorAddress = _operatorAddress;
        if(_treasuryAddress != address(0)) treasuryAddress = _treasuryAddress;
        if(_injectorAddress != address(0)) injectorAddress = _injectorAddress;

        emit NewOperatorAndTreasuryAndInjectorAddresses(
            _operatorAddress,
            _treasuryAddress,
            _injectorAddress
        );
    }

    /**
     * @notice Set oracle address
     * @dev Only callable by owner
     * @param _newOracle: oracle address
     * @dev Only callable by owner.
     */
    function setPriceOracleAddress(address _newOracle) external onlyOwner {
        priceOracle = IPriceOracle(_newOracle);
    }

    // <================================ CALL METHODS ================================>

    /**
     * @notice Calculate price of a set of tickets
     * @param _discountDivisor: divisor for the discount
     * @param _priceTicket price of a ticket (in EUPH)
     * @param _numberTickets number of tickets to buy
     * @dev call method
     */
    function calculateTotalPriceForBulkTickets(
        uint256 _discountDivisor,
        uint256 _priceTicket,
        uint256 _numberTickets
    ) external pure returns (uint256) {
        require(
            _discountDivisor >= MIN_DISCOUNT_DIVISOR,
            "Must be >= MIN_DISCOUNT_DIVISOR"
        );
        require(_numberTickets != 0, "Number of tickets must be > 0");

        return _calculateTotalPriceForBulkTickets(_discountDivisor, _priceTicket, _numberTickets);
    }

    /**
     * @notice View current lottery id
     */
    function viewCurrentLotteryId() external view returns (uint256) {
        return currentLotteryId;
    }

    /**
     * @notice View lottery information
     * @param _lotteryId: lottery id
     */
    function viewLottery(uint256 _lotteryId)
        external
        view
        returns (Lottery memory)
    {
        Lottery memory lottery = _lotteries[_lotteryId];
        
        if(!lottery.custom) {
            lottery.priceTicketInBUSD = defaultTicketPriceInBUSD;
            lottery.discountDivisor = defaultDiscountDivisor;
            lottery.maxNumberTicketsPerBuy = defaultMaxTicketsNumberPerBuy;
            lottery.treasuryShare = defaultTreasuryShare;
            lottery.competitionShare = defaultCompetitionShare;
            lottery.rewardsBreakdown = defaultRewardsBreakdown;
        }

        if(block.timestamp >= lottery.endTime && lottery.status == Status.Open) {
            lottery.status = Status.Close;
        }

        return lottery;
    }

    /**
     * @notice View list of user's participated lottery Ids
     * @param _user: user address
     */
    function viewUserLotteryIds(address _user)
        external
        view
        returns (uint256[] memory)
    {
        return _userLotteryIds[_user];
    }

    /**
     * @notice View ticket statuses and numbers for lottery of id
     * @param _lotteryId: array of _lotteryId
     */
    function viewTicketsForLotteryId(uint256 _lotteryId)
        external
        view
        returns (TicketsView memory)
    {
        uint256 ticketIdNextLottery = _lotteries[_lotteryId].firstTicketIdNextLottery;
        if(ticketIdNextLottery == 0) ticketIdNextLottery = currentTicketId;
        if(currentLotteryId == _lotteryId) ticketIdNextLottery = currentTicketId;
        uint256 length = ticketIdNextLottery -
            _lotteries[_lotteryId].firstTicketId;
        uint256 startTicketId = _lotteries[_lotteryId].firstTicketId;
        
        uint256[] memory ticketIds = new uint256[](length);
        uint32[] memory ticketNumbers = new uint32[](length);
        bool[] memory ticketStatuses = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            ticketIds[i] = startTicketId + i;
            ticketNumbers[i] = _tickets[startTicketId + i].number;
            if (_tickets[startTicketId + i].owner == address(0)) {
                ticketStatuses[i] = true;
            } else {
                ticketStatuses[i] = false;
            }
        }

        TicketsView memory ticketsView;
        ticketsView.ticketIds = ticketIds;
        ticketsView.ticketNumbers = ticketNumbers;
        ticketsView.ticketStatuses = ticketStatuses;

        return ticketsView;
    }

    /**
     * @notice View rewards for a given ticket, providing a bracket, and lottery id
     * @dev Computations are mostly offchain. This is used to verify a ticket!
     * @param _lotteryIds: lottery id
     * @param _ticketIds: ticket id
     * @param _brackets: bracket for the ticketId to verify the claim and calculate rewards
     */
     function viewRewardsForTicketIds(
        uint256[] calldata _lotteryIds,
        uint256[][] calldata _ticketIds,
        uint32[][] calldata _brackets
    ) external view returns (uint256) {
        uint result;
        
        // Check lottery is in claimable status
        for(uint i = 0; i < _lotteryIds.length; i++)
        {
            uint256 lotteryId = _lotteryIds[i];
            
            require(_lotteries[lotteryId].status == Status.Claimable, "One of provided lottery games are not claimable yet");
            
            require(_ticketIds[i].length == _brackets[i].length, "Not same length");
            require(_ticketIds[i].length != 0, "Length must be > 0");
            require(_lotteries[lotteryId].status == Status.Claimable, "Provided lottery id is not claimable");

            for(uint j = 0; j < _ticketIds[i].length; j++) {
                uint256 _ticketId = _ticketIds[i][j];
                require (
                    (_lotteries[lotteryId].firstTicketIdNextLottery > _ticketId) &&
                    (_lotteries[lotteryId].firstTicketId <= _ticketId),
                    "There is a ticket that does not belong to a provided lottery game"
                );
                result += _calculateRewardsForTicketId(lotteryId, _ticketId, _brackets[i][j], false, [uint32(0), uint32(0), uint32(0), uint32(0), uint32(0), uint32(0)]);
            }
        }

        return result;
    }

    /**
     * @notice View user ticket ids, numbers, and statuses of user for a given lottery
     * @param _user: user address
     * @param _lotteryId: lottery id
     */
    function viewUserTicketsForLotteryId(
        address _user,
        uint256 _lotteryId
    )
        public
        view
        returns (UserTicketsView memory)
    {
        uint256 numberTicketsBoughtAtLotteryId = _userSingleTicketIdsPerLotteryId[_user][_lotteryId].length;
        TicketsRange[] memory multipleTickets = _userMultipleTicketIdsPerLotteryId[_user][_lotteryId];

        for(uint256 i = 0; i < multipleTickets.length; i++) {
            numberTicketsBoughtAtLotteryId += (multipleTickets[i].endTicketId - multipleTickets[i].startTicketId);
        }

        UserTicketsView memory userTickets; 

        userTickets.ticketIds = new uint256[](numberTicketsBoughtAtLotteryId);
        userTickets.ticketNumbers = new uint32[](numberTicketsBoughtAtLotteryId);
        userTickets.ticketStatuses = new bool[](numberTicketsBoughtAtLotteryId);
        userTickets.boughtTicketsAmount = numberTicketsBoughtAtLotteryId;

        uint256 currentTicketIndex;

        for (uint256 i = 0; i < multipleTickets.length; i++) {
            uint256 ticketsNumberInRange = multipleTickets[i].endTicketId - multipleTickets[i].startTicketId;
            for(uint256 j = 0; j < ticketsNumberInRange; j++)
            {
                userTickets.ticketIds[currentTicketIndex] = multipleTickets[i].startTicketId + j;
                userTickets.ticketNumbers[currentTicketIndex] = _tickets[userTickets.ticketIds[currentTicketIndex]].number;

                // True = ticket claimed
                if (_tickets[userTickets.ticketIds[currentTicketIndex]].owner == address(0)) {
                    userTickets.ticketStatuses[currentTicketIndex] = true;
                } else {
                    // ticket not claimed (includes the ones that cannot be claimed)
                    userTickets.ticketStatuses[currentTicketIndex] = false;
                }

                currentTicketIndex++;
            }
        }

        for (uint256 i = 0; i < _userSingleTicketIdsPerLotteryId[_user][_lotteryId].length; i++) {
            userTickets.ticketIds[currentTicketIndex] = _userSingleTicketIdsPerLotteryId[_user][_lotteryId][i];
            userTickets.ticketNumbers[currentTicketIndex] = _tickets[userTickets.ticketIds[currentTicketIndex]].number;

            // True = ticket claimed
            if (_tickets[userTickets.ticketIds[currentTicketIndex]].owner == address(0)) {
                userTickets.ticketStatuses[currentTicketIndex] = true;
            } else {
                // ticket not claimed (includes the ones that cannot be claimed)
                userTickets.ticketStatuses[currentTicketIndex] = false;
            }
            
            currentTicketIndex++;
        }

        return (userTickets);
    }

    /**
     * @notice View user addresses for a lottery id
     * @param _user: user address
     */
    function viewUserLotteryBalance(
        address _user
    )
        external
        view
        returns (
            uint256
        )
    {
        return _userLotteryBalance[_user];
    }

    /**
     * @notice Get total tickets amount of lottery game
     * @param _lotteryId: id of lottery game
     */
    function getTotalTicketsAmountForLotteryId(uint256 _lotteryId)
        external
        view
        returns (uint256)
    {
        return _lotteryId == currentLotteryId ? currentTicketId - _lotteries[_lotteryId].firstTicketId : _lotteries[_lotteryId].firstTicketIdNextLottery - _lotteries[_lotteryId].firstTicketId;
    }

    /**
     * @notice View price of one ticket in EUPH token
     * @param _user: address of the user
     * @param _lotteryId: id of lottery game
     */
    function getUserWinningRewardsForLotteryId(address _user, uint256 _lotteryId)
        public
        view
        returns (uint256)
    {
        return _calculateUserRewardsForLotteryId(_user, _lotteryId);
    }

    /**
     * @notice View price of one ticket in EUPH token
     * @param _user: address of the user
     * @param _lotteryId: id of a lottery game
     */
    function getUserWinningTicketsForLotteryId(address _user, uint256 _lotteryId, bool _onlyValidTickets)
        public
        view
        returns (UserWinningTicketsView memory)
    {
        UserTicketsView memory userTickets = viewUserTicketsForLotteryId(_user, _lotteryId);
        UserWinningTicketsView memory userWinningTickets;

        uint32 finalNumber = _lotteries[_lotteryId].finalNumber;
        if(finalNumber == 0) return userWinningTickets;
        
        uint256[] memory temporaryWinningTicketIds = new uint256[](userTickets.boughtTicketsAmount);
        uint32[] memory temporaryWinningTicketBrackets = new uint32[](userTickets.boughtTicketsAmount);
        uint256 winningTicketsAmount = 0;

        for(uint256 i = 0; i < userTickets.boughtTicketsAmount; i++) { 
            if(_onlyValidTickets && userTickets.ticketStatuses[i]) continue;
            (bool isWinningTicket, uint32 bracket) = _isWinningTicket(finalNumber, userTickets.ticketIds[i]);
            if(isWinningTicket) {
                temporaryWinningTicketIds[winningTicketsAmount] = userTickets.ticketIds[i];
                temporaryWinningTicketBrackets[winningTicketsAmount] = bracket;
                winningTicketsAmount++;
            }
        }

        userWinningTickets.ticketIds = new uint256[](winningTicketsAmount);
        userWinningTickets.ticketBrackets = new uint32[](winningTicketsAmount);

        for(uint256 i = 0; i < winningTicketsAmount; i++) { 
            userWinningTickets.ticketIds[i] = temporaryWinningTicketIds[i];
            userWinningTickets.ticketBrackets[i] = temporaryWinningTicketBrackets[i];
        }

        return userWinningTickets;
    }

    /**
     * @notice See if lottery is still active to purchase tickets
     */
    function isTicketSaleAvailable()
        external
        view
        returns (bool)
    {
        return block.timestamp < _lotteries[currentLotteryId].endTime;
    }

    function viewCompetitionBalance()
        external
        view
        returns (
            uint256
        )
    {
        return competitionBalance;
    }

    function viewCollectedTicketsAmountInEUPH()
        external
        view
        returns (
            uint256
        )
    {
        return collectedTicketsAmountInEUPH;
    }

    function viewPublicAddresses() 
        external
        view
        returns(PublicAddresses memory) 
    {
        PublicAddresses memory publicAddresses;

        publicAddresses.injectorAddress = injectorAddress;
        publicAddresses.operatorAddress = operatorAddress;
        publicAddresses.treasuryAddress = treasuryAddress;
        publicAddresses.busdTokenAddress = busdTokenAddress;
        publicAddresses.euphTokenAddress = euphTokenAddress;

        return publicAddresses;
    }

    // <================================ INTERNAL/PRIVATE METHODS ================================>

    function _withdrawLotteryBalance(
        uint256 _withdrawAmount,
        uint256[] memory _lotteryIds,
        uint256[][] memory _ticketIds,
        uint32[][] memory _brackets
    ) private {
        require(_withdrawAmount != 0, "Withdraw amount must be higher than 0");
        uint256 rewardInEuphToTransfer;

        if(_lotteryIds.length != 0) {
            (rewardInEuphToTransfer, ) = _claimAllTickets(_lotteryIds, _ticketIds, _brackets);    
            rewardInEuphToTransfer += _userLotteryBalance[msg.sender];
        } else {
            rewardInEuphToTransfer = _userLotteryBalance[msg.sender];
        }
        require(rewardInEuphToTransfer >= _withdrawAmount, "Withdraw amount exceeds user lottery balance");
        if(_withdrawAmount < rewardInEuphToTransfer) {
            _userLotteryBalance[msg.sender] = rewardInEuphToTransfer - _withdrawAmount;
            rewardInEuphToTransfer = _withdrawAmount;
        } else if (_withdrawAmount == rewardInEuphToTransfer) {
            delete _userLotteryBalance[msg.sender];
        }

        euphToken.safeTransfer(msg.sender, rewardInEuphToTransfer);

        emit WithdrawLotteryBalance(
            msg.sender,
            rewardInEuphToTransfer
        );
    }

    function _buyTicketsInitialize(uint256 _lotteryId, uint256 _ticketNumbersLength) private returns(uint256) {
        bool isCustomLottery = _lotteries[_lotteryId].custom;
        uint256 discountDivisor = isCustomLottery ? _lotteries[_lotteryId].discountDivisor : defaultDiscountDivisor;
        uint maxNumberTicketsPerBuy = isCustomLottery ? _lotteries[_lotteryId].maxNumberTicketsPerBuy : defaultMaxTicketsNumberPerBuy;

        require(
            maxNumberTicketsPerBuy >= _userTicketsAmountPerLotteryId[msg.sender][_lotteryId] + _ticketNumbersLength, 
            "Provided tickets amount exceeds maximum limit or you have already purchased more tickets than maximum limit"
        );

        require(
            _lotteries[_lotteryId].status == Status.Open,
            "Lottery is not open"
        );

        require(
            block.timestamp < _lotteries[_lotteryId].endTime,
            "Lottery is over"
        );

        require(_ticketNumbersLength != 0, "No ticket specified");
        
        if(isCustomLottery) {
            require(
                _ticketNumbersLength <= _lotteries[_lotteryId].maxNumberTicketsPerBuy,
                "Too many tickets"
            );
        }

        if (_userSingleTicketIdsPerLotteryId[msg.sender][_lotteryId].length == 0 && _userMultipleTicketIdsPerLotteryId[msg.sender][_lotteryId].length == 0) {
            _userLotteryIds[msg.sender].push(_lotteryId);
        }

        // Update EUPH price for _lotteryId
        _updateEUPHPrice(_lotteryId);

        // Calculate number of EUPH to this contract
        return _calculateTotalPriceForBulkTickets(
            discountDivisor,
            _lotteries[_lotteryId].priceTicketInEUPH,
            _ticketNumbersLength
        );
    }

    function _buyTicketsFinalize(uint256 _amountEuphToTransfer, uint256 _lotteryId, uint32[] memory _ticketNumbers) private {
        // Increment the total amount collected for the lottery round
        _lotteries[_lotteryId].amountCollectedInEUPH += _amountEuphToTransfer;
        
        uint256 _startTicketId = currentTicketId;

        uint256 _currentTicketId = currentTicketId;
        for (uint256 i = 0; i < _ticketNumbers.length; i++) {
            uint32 thisTicketNumber = _ticketNumbers[i];
            uint256 thisCurrentTicketId = _currentTicketId++;
            require(
                (thisTicketNumber >= 1000000) && (thisTicketNumber <= 1999999),
                "Outside range"
            );
            
            _tickets[thisCurrentTicketId] = Ticket({
                number: thisTicketNumber,
                owner: msg.sender
            });
        }

        if(_ticketNumbers.length == 1) {
            _userSingleTicketIdsPerLotteryId[msg.sender][_lotteryId].push(currentTicketId);
        } else {
            _userMultipleTicketIdsPerLotteryId[msg.sender][_lotteryId].push(TicketsRange({
                startTicketId: _startTicketId, 
                endTicketId: currentTicketId + _ticketNumbers.length
            }));
        }

        // Increase lottery ticket number
        _userTicketsAmountPerLotteryId[msg.sender][_lotteryId] += _ticketNumbers.length;
        currentTicketId += _ticketNumbers.length;
        collectedTicketsAmountInEUPH += _amountEuphToTransfer;
    }

    /**
     * @notice Update EUPH price for lotteryID
     */
    function _updateEUPHPrice(uint256 _lotteryId) private {
        if(block.timestamp - lastPriceOracleUpdateTime < defaultPriceUpdateInterval) return;
        uint256 priceTicketInBUSD = _lotteries[_lotteryId].custom ? _lotteries[_lotteryId].priceTicketInBUSD : defaultTicketPriceInBUSD;
        
        //uint256 oldPriceInEUPH = _lotteries[_lotteryId].priceTicketInEUPH;
        uint256 newPriceInEUPH = priceOracle.consultAndUpdate(
            busdTokenAddress,
            priceTicketInBUSD,
            euphTokenAddress
        );

        _lotteries[_lotteryId].priceTicketInEUPH = newPriceInEUPH;
        lastPriceOracleUpdateTime = block.timestamp;
    }

    /**
     * @notice Calculate user rewards for a specific lottery id
     * @param _user: lottery id
     * @param _lotteryId: ticket id
     */
    function _calculateUserRewardsForLotteryId(
        address _user,
        uint256 _lotteryId
    ) internal view returns (uint256) {
        UserWinningTicketsView memory userTickets = getUserWinningTicketsForLotteryId(_user, _lotteryId, true);
        
        uint256 userWinningBalance = 0;

        uint32[6] memory transformedFinalNumbers;
        bool usePredefinedTransformedFinalNumbers = userTickets.ticketIds.length > 6;
        if(usePredefinedTransformedFinalNumbers) {
            uint32 finalNumber = _lotteries[_lotteryId].finalNumber;
            if(_lotteries[_lotteryId].euphPerBracket[0] != 0) transformedFinalNumbers[0] = _bracketCalculator[0] + (finalNumber % (uint32(10)**(1)));
            if(_lotteries[_lotteryId].euphPerBracket[1] != 0) transformedFinalNumbers[1] = _bracketCalculator[1] + (finalNumber % (uint32(10)**(2)));
            if(_lotteries[_lotteryId].euphPerBracket[2] != 0) transformedFinalNumbers[2] = _bracketCalculator[2] + (finalNumber % (uint32(10)**(3)));
            if(_lotteries[_lotteryId].euphPerBracket[3] != 0) transformedFinalNumbers[3] = _bracketCalculator[3] + (finalNumber % (uint32(10)**(4)));
            if(_lotteries[_lotteryId].euphPerBracket[4] != 0) transformedFinalNumbers[4] = _bracketCalculator[4] + (finalNumber % (uint32(10)**(5)));
            if(_lotteries[_lotteryId].euphPerBracket[5] != 0) transformedFinalNumbers[5] = _bracketCalculator[5] + (finalNumber % (uint32(10)**(6)));
        }

        for(uint256 i = 0; i < userTickets.ticketIds.length; i++) {
            uint256 calculationResult = _calculateRewardsForTicketId(_lotteryId, userTickets.ticketIds[i], userTickets.ticketBrackets[i], usePredefinedTransformedFinalNumbers, transformedFinalNumbers);
            if(calculationResult != 0) {
                userWinningBalance += calculationResult;
            }
        }

        return userWinningBalance;
    }

    /**
     * @notice Calculate rewards for a given ticket
     * @param _lotteryId: lottery id
     * @param _ticketId: ticket id
     * @param _bracket: bracket for the ticketId to verify the claim and calculate rewards
     * @param _usePredefinedTransformedFinalNumbers: bracket for the ticketId to verify the claim and calculate rewards
     * @param _transformedFinalNumbers: bracket for the ticketId to verify the claim and calculate rewards
     */
    function _calculateRewardsForTicketId(
        uint256 _lotteryId,
        uint256 _ticketId,
        uint32 _bracket,
        bool _usePredefinedTransformedFinalNumbers,
        uint32[6] memory _transformedFinalNumbers
    ) internal view returns (uint256) {
        // Retrieve the user number combination from the ticketId
        uint32 finalNumber = _lotteries[_lotteryId].finalNumber;
        uint32 winningTicketNumber = _tickets[_ticketId].number;

        // Apply transformation to verify the claim provided by the user is true
        uint32 transformedWinningNumber = _bracketCalculator[_bracket] + (winningTicketNumber % (uint32(10)**(_bracket + 1)));

        uint32 transformedFinalNumber = _usePredefinedTransformedFinalNumbers ? _transformedFinalNumbers[_bracket] : _bracketCalculator[_bracket] + (finalNumber % (uint32(10)**(_bracket + 1)));

        // Confirm that the two transformed numbers are the same, if not throw
        if (transformedWinningNumber == transformedFinalNumber) {
            return _lotteries[_lotteryId].euphPerBracket[_bracket];
        } else {
            return 0;
        }
    }

    function _isWinningTicket(uint32 _finalNumber, uint256 _ticketId) internal view returns(bool, uint32) {
        // Retrieve the user number combination from the ticketId
        uint32 winningTicketNumber = _tickets[_ticketId].number;

        for(uint32 _bracket = 5; _bracket >= 0; _bracket--) {
            // Apply transformation to verify the claim provided by the user is true
            uint32 transformedWinningNumber = _bracketCalculator[_bracket] +
                (winningTicketNumber % (uint32(10)**(_bracket + 1)));

            uint32 transformedFinalNumber = _bracketCalculator[_bracket] +
                (_finalNumber % (uint32(10)**(_bracket + 1)));

            if(transformedWinningNumber == transformedFinalNumber) {
                return (true, _bracket);
            }

            if(_bracket == 0) break;
        }
        
        return (false, 0);
    }

    /**
     * @notice Calculate final price for bulk of tickets
     * @param _discountDivisor: divisor for the discount (the smaller it is, the greater the discount is)
     * @param _priceTicket: price of a ticket
     * @param _numberTickets: number of tickets purchased
     */
    function _calculateTotalPriceForBulkTickets(
        uint256 _discountDivisor,
        uint256 _priceTicket,
        uint256 _numberTickets
    ) internal pure returns (uint256) {
        return (_priceTicket * _numberTickets * (_discountDivisor - _numberTickets)) / _discountDivisor;
    }

    /**
     * @notice Check if an address is a contract
     */
    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    /**
     * @notice Claim a set of winning tickets for a lottery
     * @param _lotteryId: lottery id
     * @param _ticketIds: array of ticket ids
     * @param _brackets: array of brackets for the ticket ids
     * @dev Callable by users only, not contract!
     */
    function _claimTicketsForLotteryId(
        uint256 _lotteryId,
        uint256[] memory _ticketIds,
        uint32[] memory _brackets
    ) internal returns (uint256) {
        require(_ticketIds.length == _brackets.length, "Not same length");
        require(_ticketIds.length != 0, "Length must be > 0");
        require(
            _lotteries[_lotteryId].status == Status.Claimable,
            "Lottery not claimable"
        );

        // Initializes the rewardInEuphToTransfer
        uint256 rewardInEuphToTransfer;

        uint32[6] memory transformedFinalNumbers;
        bool usePredefinedTransformedFinalNumbers = _ticketIds.length > 6;
        if(usePredefinedTransformedFinalNumbers) {
            uint32 finalNumber = _lotteries[_lotteryId].finalNumber;
            if(_lotteries[_lotteryId].euphPerBracket[0] != 0) transformedFinalNumbers[0] = _bracketCalculator[0] + (finalNumber % (uint32(10)**(1)));
            if(_lotteries[_lotteryId].euphPerBracket[1] != 0) transformedFinalNumbers[1] = _bracketCalculator[1] + (finalNumber % (uint32(10)**(2)));
            if(_lotteries[_lotteryId].euphPerBracket[2] != 0) transformedFinalNumbers[2] = _bracketCalculator[2] + (finalNumber % (uint32(10)**(3)));
            if(_lotteries[_lotteryId].euphPerBracket[3] != 0) transformedFinalNumbers[3] = _bracketCalculator[3] + (finalNumber % (uint32(10)**(4)));
            if(_lotteries[_lotteryId].euphPerBracket[4] != 0) transformedFinalNumbers[4] = _bracketCalculator[4] + (finalNumber % (uint32(10)**(5)));
            if(_lotteries[_lotteryId].euphPerBracket[5] != 0) transformedFinalNumbers[5] = _bracketCalculator[5] + (finalNumber % (uint32(10)**(6)));
        }

        for (uint256 i = 0; i < _ticketIds.length; i++) {
            require(_brackets[i] < 6, "Bracket out of range"); // Must be between 0 and 5

            uint256 thisTicketId = _ticketIds[i];

            require(
                _lotteries[_lotteryId].firstTicketIdNextLottery > thisTicketId,
                "TicketId too high"
            );
            require(
                _lotteries[_lotteryId].firstTicketId <= thisTicketId,
                "TicketId too low"
            );
            require(
                msg.sender == _tickets[thisTicketId].owner,
                "Not the owner"
            );

            // Update the lottery ticket owner to 0x address
            _tickets[thisTicketId].owner = address(0);

            uint256 rewardForTicketId = _calculateRewardsForTicketId(
                _lotteryId,
                thisTicketId,
                _brackets[i],
                usePredefinedTransformedFinalNumbers,
                transformedFinalNumbers
            );

            // Check user is claiming the correct bracket
            require(rewardForTicketId != 0, "No prize for this bracket");

            if (_brackets[i] != 5) {
                require(
                    _calculateRewardsForTicketId(
                        _lotteryId,
                        thisTicketId,
                        _brackets[i] + 1,
                        usePredefinedTransformedFinalNumbers,
                        transformedFinalNumbers
                    ) == 0,
                    "Bracket must be higher"
                );
            }

            // Increment the reward to transfer
            rewardInEuphToTransfer += rewardForTicketId;
        }

        return rewardInEuphToTransfer;
    }

    function _claimAllTickets(
        uint256[] memory _lotteryIds,
        uint256[][] memory _ticketIds,
        uint32[][] memory _brackets
    ) internal returns (uint256, uint256) {
        uint256 winningEuphAmount;
        uint256 ticketNumbers;

        for (uint256 i = 0; i < _lotteryIds.length; i++) {
            // Initializes the rewardInEuphToTransfer
            winningEuphAmount += _claimTicketsForLotteryId(
                _lotteryIds[i],
                _ticketIds[i],
                _brackets[i]
            );
            ticketNumbers += _ticketIds[i].length;
        }

        return (winningEuphAmount, ticketNumbers);
    }

    /**
     * @notice Withdraw burn, referrals and competitions pool
     * @param _lotteryId: lottery Id
     * @dev Return collected amount without withdrawal burn ref and comp sum
     */
    function _withdrawTreasuryAndCompetition(uint256 _lotteryId)
        internal
        returns (uint256)
    {
        uint256 treasuryShare;
        uint256 competitionShare;

        if(_lotteries[_lotteryId].custom) {
            treasuryShare = _lotteries[_lotteryId].treasuryShare;
            competitionShare = _lotteries[_lotteryId].competitionShare;
        } else {
            treasuryShare = defaultTreasuryShare;
            competitionShare = defaultCompetitionShare;
        }

        uint256 collectedAmount = _lotteries[_lotteryId].amountCollectedInEUPH;
        uint256 treasurySum = (collectedAmount * treasuryShare) / 10000;
        uint256 competitionSum = (collectedAmount * competitionShare) / 10000;
        euphToken.safeTransfer(treasuryAddress, treasurySum);
        competitionBalance += competitionSum;
        return (collectedAmount - treasurySum - competitionSum);
    }
}
