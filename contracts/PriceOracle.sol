// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library FixedPoint {
    // range: [0, 2**112 - 1]
    // resolution: 1 / 2**112
    struct uq112x112 {
        uint224 _x;
    }

    // range: [0, 2**144 - 1]
    // resolution: 1 / 2**112
    struct uq144x112 {
        uint256 _x;
    }

    uint8 private constant RESOLUTION = 112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 x) internal pure returns (uq112x112 memory) {
        return uq112x112(uint224(x) << RESOLUTION);
    }

    // encodes a uint144 as a UQ144x112
    function encode144(uint144 x) internal pure returns (uq144x112 memory) {
        return uq144x112(uint256(x) << RESOLUTION);
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function div(uq112x112 memory self, uint112 x)
        internal
        pure
        returns (uq112x112 memory)
    {
        require(x != 0, "FixedPoint: DIV_BY_ZERO");
        return uq112x112(self._x / uint224(x));
    }

    // multiply a UQ112x112 by a uint, returning a UQ144x112
    // reverts on overflow
    function mul(uq112x112 memory self, uint256 y)
        internal
        pure
        returns (uq144x112 memory)
    {
        uint256 z;
        require(
            y == 0 || (z = uint256(self._x) * y) / y == uint256(self._x),
            "FixedPoint: MULTIPLICATION_OVERFLOW"
        );
        return uq144x112(z);
    }

    // returns a UQ112x112 which represents the ratio of the numerator to the denominator
    // equivalent to encode(numerator).div(denominator)
    function fraction(uint112 numerator, uint112 denominator)
        internal
        pure
        returns (uq112x112 memory)
    {
        require(denominator > 0, "FixedPoint: DIV_BY_ZERO");
        return uq112x112((uint224(numerator) << RESOLUTION) / denominator);
    }

    // decode a UQ112x112 into a uint112 by truncating after the radix point
    function decode(uq112x112 memory self) internal pure returns (uint112) {
        return uint112(self._x >> RESOLUTION);
    }

    // decode a UQ144x112 into a uint144 by truncating after the radix point
    function decode144(uq144x112 memory self) internal pure returns (uint144) {
        return uint144(self._x >> RESOLUTION);
    }
}

interface IEuphoriaPair {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function swapFee() external view returns (uint32);

    function devFee() external view returns (uint32);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;

    function setSwapFee(uint32) external;

    function setDevFee(uint32) external;
}

library EUPHOracleLibrary {
    using FixedPoint for *;

    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(address pair)
        internal
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        )
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IEuphoriaPair(pair).price0CumulativeLast();
        price1Cumulative = IEuphoriaPair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        ) = IEuphoriaPair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative +=
                uint256(FixedPoint.fraction(reserve1, reserve0)._x) *
                timeElapsed;
            // counterfactual
            price1Cumulative +=
                uint256(FixedPoint.fraction(reserve0, reserve1)._x) *
                timeElapsed;
        }
    }
}

contract Oracle {
    using FixedPoint for *;

    struct Observation {
        uint256 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    address public immutable factory;
    address public operatorAddress;
    uint256 public updateCycle = 30 minutes;

    bytes32 INIT_CODE_HASH; //00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5

    // mapping from pair address to a list of price observations of that pair
    mapping(address => Observation) public pairObservations;

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    constructor(
        address factory_,
        bytes32 INIT_CODE_HASH_,
        address operator_
    ) {
        factory = factory_;
        INIT_CODE_HASH = INIT_CODE_HASH_;
        operatorAddress = operator_;
    }

    function setUpdateCycle(uint256 newCycle) external onlyOperator {
        updateCycle = newCycle;
    }

    function changeOperator(address newOperator) external onlyOperator {
        operatorAddress = newOperator;
    }

    function sortTokens(address tokenA, address tokenB)
        public
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "EUPHSwapFactory: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "EUPHSwapFactory: ZERO_ADDRESS");
    }

    function pairFor(address tokenA, address tokenB)
        public
        view
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    function update(address tokenA, address tokenB) external {
        address pair = pairFor(tokenA, tokenB);

        Observation storage observation = pairObservations[pair];
        uint256 timeElapsed = block.timestamp - observation.timestamp;
        require(timeElapsed >= updateCycle, "EUPHOracle: PERIOD_NOT_ELAPSED");
        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,

        ) = EUPHOracleLibrary.currentCumulativePrices(pair);
        observation.timestamp = block.timestamp;
        observation.price0Cumulative = price0Cumulative;
        observation.price1Cumulative = price1Cumulative;
    }

    function consultAndUpdate(
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) external returns (uint256) {
        address pair = pairFor(tokenIn, tokenOut);
        Observation storage observation = pairObservations[pair];

        uint256 timeElapsed = block.timestamp - observation.timestamp;
        uint256 price;
        (uint256 price0Cumulative, uint256 price1Cumulative,) = EUPHOracleLibrary.currentCumulativePrices(pair);

        if (pairObservations[pair].price0Cumulative == 0 || pairObservations[pair].price1Cumulative == 0)
        {
            price = 0;
        } else {
            (address token0, ) = sortTokens(tokenIn, tokenOut);

            if (token0 == tokenIn) {
                price = computeAmountOut(
                    observation.price0Cumulative,
                    price0Cumulative,
                    timeElapsed,
                    amountIn
                );
            } else {
                price = computeAmountOut(
                    observation.price1Cumulative,
                    price1Cumulative,
                    timeElapsed,
                    amountIn
                );
            }
        }

        if (timeElapsed >= updateCycle) {
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
        }
        return price;
    }

    function computeAmountOut(
        uint256 priceCumulativeStart,
        uint256 priceCumulativeEnd,
        uint256 timeElapsed,
        uint256 amountIn
    ) private pure returns (uint256 amountOut) {
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    function consult(
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) external view returns (uint256 amountOut) {
        address pair = pairFor(tokenIn, tokenOut);
        Observation storage observation = pairObservations[pair];

        if (
            pairObservations[pair].price0Cumulative == 0 ||
            pairObservations[pair].price1Cumulative == 0
        ) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - observation.timestamp;
        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,

        ) = EUPHOracleLibrary.currentCumulativePrices(pair);
        (address token0, ) = sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            return
                computeAmountOut(
                    observation.price0Cumulative,
                    price0Cumulative,
                    timeElapsed,
                    amountIn
                );
        } else {
            return
                computeAmountOut(
                    observation.price1Cumulative,
                    price1Cumulative,
                    timeElapsed,
                    amountIn
                );
        }
    }
}
