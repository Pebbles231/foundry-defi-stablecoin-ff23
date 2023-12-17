//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address btc;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_DSCE_BALANCE = 10000 ether;
    uint256 public constant INITIAL_MINT_VALID_LOW = 5000 ether;
    uint256 public constant INITIAL_MINT_VALID = 10000 ether;
    uint256 public constant INITIAL_MINT_INVALID = 20000 ether;
    uint256 public constant BURN_AMOUNT = 5000 ether;
    uint256 public constant BURN_1000 = 1000 ether;
    uint256 public constant BURN_2000 = 2000 ether;
    uint256 public constant BURN_5000 = 5000 ether;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, btc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////
    // modifiers  ///////
    /////////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndDscMinted() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(INITIAL_MINT_VALID);
        vm.stopPrank();
        _;
    }

    /////////////////////////////
    /// Constructor Tests ///////
    /////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////
    /// Price Tests ///////
    ///////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // $2,000 / ETH, $100
        uint256 exptectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(exptectedWeth, actualWeth);
    }

    function testAccountCollateralValue() public depositedCollateral {
        uint256 actualUserValueInUsd = dsce.getAccountCollateralValue(USER);
        // 10ETH * $2,000/ETH = $20,000
        uint256 expectedUserValueInUsd = 20000 ether;
        assertEq(actualUserValueInUsd, expectedUserValueInUsd);
    }

    ////////////////////////////////////
    /// Deposit Collateral Tests ///////
    ////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertwithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        deal(address(ranToken), USER, STARTING_ERC20_BALANCE);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralDeposited(address(USER), address(weth), AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ////////////////////////////////////
    ///     Mint DSC Tests       ///////
    ////////////////////////////////////

    function testHealthFactorCalculationBeforeMint() public depositedCollateral {
        uint256 healthfactorBeforeMint = dsce.getHealthFactor(USER);

        assertEq(healthfactorBeforeMint, type(uint256).max);
    }

    function testMintDscWithGoodHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID);
        vm.stopPrank();
        (uint256 actualDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(actualDscMinted, INITIAL_MINT_VALID);
    }

    function testMintDscWithBadHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        // (20,000 * 50) / 100 = 10,000
        // (10,000 * 1e18) / 20,000 = 5e17
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 5e17));
        dsce.mintDsc(INITIAL_MINT_INVALID);
        vm.stopPrank();
    }

    ////////////////////////////////////
    /// Redeem Collateral Tests  ///////
    ////////////////////////////////////

    function testRevertsIfRedeemCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralPartial() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID_LOW);
        (, uint256 collateralPriorRedemption) = dsce.getAccountInformation(USER);
        dsce.redeemCollateral(address(weth), 1 ether);
        vm.stopPrank();
        uint256 expectedCollateralValue = collateralPriorRedemption - 2000 ether;
        (, uint256 collateralPostRedemption) = dsce.getAccountInformation(USER);
        assertEq(collateralPostRedemption, expectedCollateralValue);
    }

    function testRedeemCollateralEmitCollateralRedeemed() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID_LOW);

        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(address(USER), address(USER), address(weth), 1 ether);

        dsce.redeemCollateral(address(weth), 1 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralAndBurnDsc() public depositedCollateralAndDscMinted {
        (uint256 priorDscMinted, uint256 priorCollateralValue) = dsce.getAccountInformation(USER);
        vm.startPrank(USER);

        ERC20(dsc).approve(address(dsce), BURN_2000);
        dsce.redeemCollateralForDsc(weth, 1 ether, BURN_2000);
        vm.stopPrank();

        (uint256 dscMinted, uint256 collateralValue) = dsce.getAccountInformation(USER);

        assertEq(dscMinted, priorDscMinted - BURN_2000);
        assertEq(collateralValue, priorCollateralValue - BURN_2000);
    }

    function testRedeemCollateralAndBurnDscIsNotZero() public depositedCollateralAndDscMinted {
        vm.startPrank(USER);

        ERC20(dsc).approve(address(dsce), BURN_2000);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, BURN_2000);
        vm.stopPrank();
    }

    function testRedeemCollateralComplete() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        (, uint256 collateralPostRedemption) = dsce.getAccountInformation(USER);
        assertEq(collateralPostRedemption, 0);
    }

    function testRedeemCollateralBrokenHealthFactor() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID);
        // (18,000 * 50) / 100 = 9000
        // (9000 * 1e18) / 10,000 = 9e17
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 9e17));
        dsce.redeemCollateral(address(weth), 1 ether);
        vm.stopPrank();
    }

    ////////////////////////////////////
    ///    Burn DSC Tests        ///////
    ////////////////////////////////////

    function testBurnDscPartial() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID);
        ERC20(dsc).approve(address(dsce), BURN_AMOUNT);
        dsce.burnDsc(BURN_AMOUNT);
        vm.stopPrank();
        (uint256 totalMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalMinted, BURN_AMOUNT);
    }

    function testBurnDscMoreThanZero() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID);
        ERC20(dsc).approve(address(dsce), BURN_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnDscComplete() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(INITIAL_MINT_VALID);
        ERC20(dsc).approve(address(dsce), INITIAL_MINT_VALID);
        dsce.burnDsc(INITIAL_MINT_VALID);
        vm.stopPrank();
        (uint256 totalMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalMinted, 0);
    }

    ////////////////////////////////////
    ///     Liquidation Tests    ///////
    ////////////////////////////////////

    function testLiquidationRevertIfHealthFactorOk() public depositedCollateralAndDscMinted {
        vm.startPrank(LIQUIDATOR);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(address(weth), USER, BURN_1000);

        vm.stopPrank();
    }

    function testLiquidationImproveHealthFactor() public depositedCollateralAndDscMinted {
        //Update Price of ETH so that HealthFactor becomes unhealthy
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1800e8);
        deal(address(dsc), LIQUIDATOR, STARTING_DSCE_BALANCE);
        vm.startPrank(LIQUIDATOR);
        // Initial Price:
        // (20,000 * 50) / 100 = 10000
        // (10,000 * 1e18) / 10,000 = 1e18

        // After Price Updated & Liquidation expected
        // (12,500 * 50) / 100 = 6250
        // (6250 * 1e18) / 5000 = 1.25e18
        // -> if we Burn 5000 of the 10,000, the health factor should be restored

        ERC20(dsc).approve(address(dsce), BURN_5000);
        dsce.liquidate(address(weth), USER, BURN_5000);
        vm.stopPrank();

        (uint256 dscMinted,) = dsce.getAccountInformation(USER);
        assertEq(dscMinted, INITIAL_MINT_VALID - BURN_5000);
    }

    function testLiquidationNotImprovedFactor() public {}

    function testLiquidationRevertsWhenDebtToCoverIsZero() public depositedCollateralAndDscMinted {
        //Update Price of ETH so that HealthFactor becomes unhealthy
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1800e8);
        deal(address(dsc), LIQUIDATOR, STARTING_DSCE_BALANCE);
        vm.startPrank(LIQUIDATOR);
        ERC20(dsc).approve(address(dsce), BURN_5000);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.liquidate(address(weth), USER, 0);
        vm.stopPrank();
    }

    function testLiquidatorReceivesInventive() public depositedCollateralAndDscMinted {
        //Update Price of ETH so that HealthFactor becomes unhealthy
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1800e8);
        deal(address(dsc), LIQUIDATOR, STARTING_DSCE_BALANCE);
        vm.startPrank(LIQUIDATOR);
        // Initial Price:
        // (20,000 * 50) / 100 = 10000
        // (10,000 * 1e18) / 10,000 = 1e18

        // After Price Updated & Liquidation expected
        // (12,500 * 50) / 100 = 6250
        // (6250 * 1e18) / 5000 = 1.25e18
        // -> if we Burn 5000 of the 10,000, the health factor should be restored
        // -> WETH Balance of Liquidator after liquidation should be 3.05555555556

        ERC20(dsc).approve(address(dsce), BURN_5000);
        dsce.liquidate(address(weth), USER, BURN_5000);
        vm.stopPrank();

        uint256 redeemedCollateral = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedRedeemedCollateral = dsce.getTokenAmountFromUsd(weth, (BURN_5000 + 500 ether));
        assertEq(redeemedCollateral, (expectedRedeemedCollateral - 1 wei));
    }
}
