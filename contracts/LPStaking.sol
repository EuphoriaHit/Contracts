// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IPancakePair.sol";

interface Staking {
  function createStakeLP(address stakeHolder, uint256 stakeAmount) external;
  function unStakeLP(address stakeHolder) external;
}

contract LPStaking is Ownable {
    constructor(address uniswapAddress, address pancakeAddress, address stakingAddress, address euphAddress, address busdAddress, address usdtAddress) {
        uniswapRouter = IUniswapV2Router02(uniswapAddress);
        pancakeswapRouter = IPancakeRouter02(pancakeAddress);
        staking = Staking(stakingAddress);
        euph = IERC20(euphAddress);
        busd = IERC20(busdAddress);
        usdt = IERC20(usdtAddress);
    }

    IUniswapV2Router02 private uniswapRouter;
    IPancakeRouter02 private pancakeswapRouter;
    IUniswapV2Pair private uniswapPair;
    IPancakePair private pancakeswapPair;
    Staking private staking;
    IERC20 private euph;
    IERC20 private busd;
    IERC20 private usdt;
    mapping(address => uint256) uniswapUserLP;
    mapping(address => uint256) pancakeswapUserLP;

    function addLiquidityPancake(uint256 amountEUPH, uint256 amountBUSD) external {
        address lpUser = _msgSender();
        (uint256 sentEUPH, uint256 sentBUSD, uint256 liquidity) = _addLiquidityPancake(lpUser, amountEUPH, amountBUSD);
        pancakeswapUserLP[msg.sender] += liquidity;
        staking.createStakeLP(lpUser, amountEUPH);

        emit AddedLiquidityOnPancakeswap(sentEUPH, sentBUSD, liquidity);
    }

    function addLiquidityUniswap(uint256 amountEUPH, uint256 amountUSDT) external {
        address lpUser = _msgSender();
        (uint256 sentEUPH, uint256 sentUSDT, uint256 liquidity) = _addLiquidityUniswap(lpUser, amountEUPH, amountUSDT);
        uniswapUserLP[msg.sender] += liquidity;
        staking.createStakeLP(lpUser, amountEUPH);

        emit AddedLiquidityOnUniswap(sentEUPH, sentUSDT, liquidity);
    }

    function removeLiquidityPancake() external {
        address lpUser = _msgSender();
        (uint256 receivedEUPH, uint256 receivedBUSD) = _removeLiquidityPancake(lpUser);
        delete pancakeswapUserLP[lpUser];
        staking.unStakeLP(lpUser);

        emit RemovedLiquidityOnPancakeswap(receivedEUPH, receivedBUSD);
    }

    function removeLiquidityUniswap() external {
        address lpUser = _msgSender();
        (uint256 receivedEUPH, uint256 receivedUSDT) = _removeLiquidityUniswap(lpUser);
        delete uniswapUserLP[lpUser];
        staking.unStakeLP(lpUser);

        emit RemovedLiquidityOnUniswap(receivedEUPH, receivedUSDT);
    }

    function _addLiquidityPancake(address lpUser, uint256 amountEUPH, uint256 amountBUSD) private returns (uint256 sentEUPH, uint256 sentBUSD, uint256 liquidity){
        (sentEUPH, sentBUSD, liquidity) = pancakeswapRouter.addLiquidity(
            address(euph),
            address(busd),
            amountEUPH,
            amountBUSD,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            lpUser,
            block.timestamp
        );
    }

        function _addLiquidityUniswap(address lpUser, uint256 amountEUPH, uint256 amountUSDT) private returns (uint256 sentEUPH, uint256 sentUSDT, uint256 liquidity){
        (sentEUPH, sentUSDT, liquidity) = uniswapRouter.addLiquidity(
            address(euph),
            address(usdt),
            amountEUPH,
            amountUSDT,
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
        address user = _msgSender();
        uint256 liquidity = pancakeswapUserLP[user];
        pancakeswapPair.approve(address(this), liquidity);
        pancakeswapPair.approve(address(pancakeswapRouter), liquidity);

        (amountEUPH, amountBUSD) = pancakeswapRouter.removeLiquidity(
            address(euph),
            address(busd),
            liquidity,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            lpUser,
            addMinsTimestamp(block.timestamp, 30)
        );
    }

    function _removeLiquidityUniswap(address lpUser)
        private
        returns (uint256 amountEUPH, uint256 amountUSDT)
    {
        address user = _msgSender();
        uint256 liquidity = uniswapUserLP[user];
        uniswapPair.approve(address(this), liquidity);
        uniswapPair.approve(address(uniswapRouter), liquidity);

        (amountEUPH, amountUSDT) = uniswapRouter.removeLiquidity(
            address(euph),
            address(usdt),
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
    
    event AddedLiquidityOnPancakeswap(uint256 sentEUPH, uint256 sentBUSD, uint256 liquidity);

    event AddedLiquidityOnUniswap(uint256 sentEUPH, uint256 sentUSDT, uint256 liquidity);

    event RemovedLiquidityOnPancakeswap(uint256 receivedEUPH, uint256 receivedBUSD);

    event RemovedLiquidityOnUniswap(uint256 receivedEUPH, uint256 receivedUSDT);
}