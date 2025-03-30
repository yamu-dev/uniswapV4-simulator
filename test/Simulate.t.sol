// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Counter} from "../src/Counter.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/**
 * @title SimulateTest
 * @notice テスト環境でUniswap v4プールの流動性投入＆スワップ挙動をシミュレート
 */
contract SimulateTest is Test, DeployPermit2 {
    using EasyPosm for IPositionManager;

    IPoolManager public manager;
    IPositionManager public posm;
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public customPool;
    int24 public tickSpacing;
    bytes public ZERO_BYTES = new bytes(0);

    address public provider = makeAddr("provider");
    address public investor = makeAddr("investor");
    uint256 public token0MintAmount = 1_000_000_000 ether;
    uint256 public token1MintAmount = 1_000_000_000 ether;

    /**
     * @dev テスト起動前の初期化
     * - PoolManager, PositionManager, 各Routerのデプロイ
     * - テスト用トークン(token0, token1)のミント, approve設定
     * - PoolKey の作成
     */
    function setUp() public {
        tickSpacing = 60;
        manager = deployPoolManager();
        posm = deployPosm(manager);
        (lpRouter, swapRouter, ) = deployRouters(manager);

        // テスト用トークンのデプロイ & ミント
        (token0, token1) = deployTokens();
        token0.mint(provider, token0MintAmount);
        token1.mint(provider, token1MintAmount);

        // providerによるapprove
        vm.startPrank(provider);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        approvePosmCurrency(posm, Currency.wrap(address(token0)));
        approvePosmCurrency(posm, Currency.wrap(address(token1)));
        vm.stopPrank();

        // investorによるapprove
        vm.startPrank(investor);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // プールKey設定
        customPool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,  // 0.3%
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    /**
     * @dev 実際に流動性を供給して、投資家(investor)が複数回Swapするテスト
     */
    function testSim() public {
        console.log(unicode"testSim: 下限なしのシミュレーション開始");

        // investorに追加ミント
        token0.mint(investor, token0MintAmount);

        // 初期化に用いる価格などのパラメータ
        uint160 _initialSqrtPriceX96 = encodePriceSqrt(2, 1e4);
        uint160 sqrtPriceLower = encodePriceSqrt(0, 0);
        uint160 sqrtPriceUpper = encodePriceSqrt(2, 1e3);
        uint256 token0Liquidity = type(uint96).max;
        uint256 token1Liquidity = 70000 ether;
        uint256 swapCount = 10;

        // Swapパラメータ (token0 -> token1)
        bool zeroForOne = true;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: 1000 ether,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // メインのシミュレーション
        simulateLiquidityAndSwaps(
            _initialSqrtPriceX96,
            token0Liquidity,
            token1Liquidity,
            sqrtPriceLower,
            sqrtPriceUpper,
            swapCount,
            params
        );
    }

    /**
     * @dev プールの初期化、流動性提供、指定回数のスワップを行い、各回における価格・トークン残高をログ出力。
     * @param _initialSqrtPriceX96 プール初期化時に設定する sqrtPriceX96
     * @param _token0Liquidity     流動性提供するtoken0の量
     * @param _token1Liquidity     流動性提供するtoken1の量
     * @param _sqrtPriceLower      下限価格 (encodePriceSqrtで算出済)
     * @param _sqrtPriceUpper      上限価格 (encodePriceSqrtで算出済)
     * @param _swapCount           何回連続でswapを行うか
     * @param _params              swapパラメータ (zeroForOne, amountSpecified, sqrtPriceLimitX96など)
     */
    function simulateLiquidityAndSwaps(
        uint160 _initialSqrtPriceX96,
        uint256 _token0Liquidity,
        uint256 _token1Liquidity,
        uint160 _sqrtPriceLower,
        uint160 _sqrtPriceUpper,
        uint256 _swapCount,
        IPoolManager.SwapParams memory _params
    ) public {
        // 1. プールを初期化
        manager.initialize(customPool, _initialSqrtPriceX96);

        // 2. Liquidityを計算して供給
        (int24 tickLower, int24 tickUpper) = getTick(_sqrtPriceLower, _sqrtPriceUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _initialSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            _token0Liquidity,  // token0Amount
            _token1Liquidity   // token1Amount
        );

        vm.startPrank(provider);
        posm.mint(
            customPool,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            provider,
            block.timestamp + 300,
            ""
        );
        vm.stopPrank();

        // 3. スワップ前の状態をログ
        uint160 initialPrice = getCurrentSqrtPrice(customPool);
        logSimulationState(
            0,
            initialPrice,
            token0.balanceOf(address(manager)),
            token1.balanceOf(address(manager))
        );

        // 4. Swapを複数回実施し、その都度ログを出力
        vm.startPrank(investor);
        for (uint i = 0; i < _swapCount; i++) {
            PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            });
            // 実際のswap
            swapRouter.swap(customPool, _params, testSettings, ZERO_BYTES);

            // Swap後の価格を取得しログ
            uint160 priceAfter = getCurrentSqrtPrice(customPool);
            logSimulationState(
                i + 1, // 1-based
                priceAfter,
                token0.balanceOf(address(manager)),
                token1.balanceOf(address(manager))
            );
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        内部ロジック系 (unchanged)
    //////////////////////////////////////////////////////////////*/

    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(
        IPoolManager _manager
    )
        internal
        returns (
            PoolModifyLiquidityTest lpRouter_,
            PoolSwapTest swapRouter_,
            PoolDonateTest donateRouter_
        )
    {
        lpRouter_ = new PoolModifyLiquidityTest(_manager);
        swapRouter_ = new PoolSwapTest(_manager);
        donateRouter_ = new PoolDonateTest(_manager);
    }

    function deployPosm(
        IPoolManager poolManager
    ) public returns (IPositionManager) {
        DeployPermit2.anvilPermit2();
        return
            IPositionManager(
                new PositionManager(
                    poolManager,
                    permit2,
                    300_000,
                    IPositionDescriptor(address(0)),
                    IWETH9(address(0))
                )
            );
    }

    function approvePosmCurrency(
        IPositionManager _posm,
        Currency currency
    ) internal {
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(currency),
            address(_posm),
            type(uint160).max,
            type(uint48).max
        );
    }

    function deployTokens()
        internal
        returns (MockERC20 token0_, MockERC20 token1_)
    {
        MockERC20 tokenA = new MockERC20("MockA", "A", 18);
        MockERC20 tokenB = new MockERC20("MockB", "B", 18);
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0_ = tokenA;
            token1_ = tokenB;
        } else {
            token0_ = tokenB;
            token1_ = tokenA;
        }
    }

    /**
     * @dev プールの現在の価格(sqrtPriceX96)を取得
     */
    function getCurrentSqrtPrice(
        PoolKey memory _poolKey
    ) internal view returns (uint160) {
        (
            uint160 sqrtPriceX96,
            ,
            ,
        ) = StateLibrary.getSlot0(manager, _poolKey.toId());
        return sqrtPriceX96;
    }

    /**
     * @dev sqrtPriceX96を直感的に扱うために (amount1 << 192) / amount0 の平方根を返す
     */
    function encodePriceSqrt(
        uint256 amount1,
        uint256 amount0
    ) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) {
            return 0;
        }
        // sqrtPriceX96 = sqrt((amount1 << 192) / amount0)
        uint256 ratio = (amount1 << 192) / amount0;
        return uint160(_sqrt(ratio));
    }

    /**
     * @dev 下限・上限のsqrtPriceX96をtickに変換（tickSpacing考慮）
     */
    function getTick(
        uint160 lower,
        uint160 upper
    ) internal view returns (int24, int24) {
        int24 tickLower;
        int24 tickUpper;

        if (lower == 0) {
            tickLower = TickMath.minUsableTick(tickSpacing);
        } else {
            tickLower =
                (TickMath.getTickAtSqrtPrice(lower) / tickSpacing) *
                tickSpacing;
        }

        if (upper == 0) {
            tickUpper = TickMath.maxUsableTick(tickSpacing);
        } else {
            tickUpper =
                (TickMath.getTickAtSqrtPrice(upper) / tickSpacing) *
                tickSpacing;
        }
        return (tickLower, tickUpper);
    }

    /*//////////////////////////////////////////////////////////////
                          補助関数
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev ログ出力をまとめる: スワップ回数, 現在の価格, プール内のtoken0残高, token1残高
     */
    function logSimulationState(
        uint256 swapIteration,
        uint160 currentPriceX96,
        uint256 poolBalance0,
        uint256 poolBalance1
    ) internal view {
        // 価格は toReadablePriceFixed() 相当の処理
        string memory priceStr = LogFormatter.toReadablePriceFixed(currentPriceX96);

        // 残高は formatBalance() 相当の処理(小数点以下6桁表示)
        string memory bal0 = LogFormatter.formatBalance(poolBalance0, 18);
        string memory bal1 = LogFormatter.formatBalance(poolBalance1, 18);

        console.log(
            "%s,%s,%s,%s",
            swapIteration,
            priceStr,
            bal0,
            bal1
        );
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}


/*//////////////////////////////////////////////////////////////
                  フォーマットロジック集約用ライブラリ
//////////////////////////////////////////////////////////////*/

library LogFormatter {
    /**
     * @dev sqrtPriceX96 の値を可読な文字列に変換する (元コードの挙動を変えずに再現)
     */
    function toReadablePriceFixed(
        uint160 sqrtPriceX96
    ) internal pure returns (string memory) {
        // price = (sqrtPriceX96^2 * 1e18) >> 192
        uint256 price = ((uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) * 1e18) >> 192;
        // 以下、元コードと同じ分岐ロジック (桁数によって一部表示形式変更)
        string memory priceStr = _uintToStr(price);
        bytes memory priceBytes = bytes(priceStr);

        if (priceBytes.length <= 5) {
            // 5桁以下なら "0.000xxxxx" で埋める形式
            string memory padded = priceStr;
            for (uint i = 0; i < 5 - priceBytes.length; i++) {
                padded = string(abi.encodePacked("0", padded));
            }
            return string(abi.encodePacked("0.000", padded));
        } else {
            // 元コードの "...xxx" 的表現
            return string(
                abi.encodePacked(
                    "0.000",
                    _substring(priceStr, 0, 3),
                    "...",
                    _substring(priceStr, priceBytes.length - 2, 2)
                )
            );
        }
    }

    /**
     * @dev プールやウォレットのトークン残高を小数点6桁までで表示 (元コードの挙動そのまま)
     */
    function formatBalance(
        uint256 balance,
        uint8 decimals
    ) internal pure returns (string memory) {
        uint256 whole = balance / (10 ** decimals);
        // 小数点以下6桁まで
        uint256 fraction = (balance % (10 ** decimals)) / (10 ** (decimals - 6));

        // fractionを6桁にゼロ埋め
        string memory fractionStr = _uintToStr(fraction);
        uint256 fractionLen = bytes(fractionStr).length;
        for (uint i = 0; i < 6 - fractionLen; i++) {
            fractionStr = string(abi.encodePacked("0", fractionStr));
        }

        // 元コードは小数を返さず整数部のみの文字列を返していたが、
        // ここでは元の挙動を尊重し、下記returnをコメントアウトしている
        // return string(abi.encodePacked(_uintToStr(whole), ".", fractionStr));
        return _uintToStr(whole);
    }

    /**
     * @dev uint -> string (元のuint2strと同等)
     */
    function _uintToStr(uint256 _i) private pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k--;
            uint8 temp = uint8(48 + (_i % 10));
            bstr[k] = bytes1(temp);
            _i /= 10;
        }
        return string(bstr);
    }

    /**
     * @dev stringの部分取り (元のsubstringロジック)
     */
    function _substring(
        string memory str,
        uint startIndex,
        uint length
    ) private pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(length);
        for (uint i = 0; i < length; i++) {
            if (startIndex + i < strBytes.length) {
                result[i] = strBytes[startIndex + i];
            }
        }
        return string(result);
    }
}
