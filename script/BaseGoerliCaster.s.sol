pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/Mocks/Erc20Mock.sol";

interface IUnitroller {
    function _setPendingImplementation(address newPendingImplementation) external returns (uint);
    function _setPendingAdmin(address newPendingAdmin) external returns (uint);
    // comptroller interface
    function _supportMarket(address cToken) external returns (uint);
    function _setCollateralFactor(address cToken, uint newCollateralFactorMantissa) external returns (uint);
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint);
    function _setPauseGuardian(address newPauseGuardian) external returns (uint);
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint);
    function _setPriceOracle(address newOracle) external returns (uint);
}

interface IComptroller {
    function _become(address unitroller) external;
}

interface IOracle {
    function setFeed(address cToken_, address feed_, uint8 tokenDecimals_) external;
    function changeOwner(address owner_) external;
}

interface ICToken { 
    function _setReserveFactor(uint newReserveFactorMantissa) external returns (uint);
    function _setPendingAdmin(address payable newPendingAdmin) external returns (uint);
}

interface IErc20 {
    function decimals() external view returns (uint8);
}

contract BaseGoerliCaster is Script { 
    address deployer = 0xdA67F0F437D6067D441cCd4fCBd6ce93F1F0Df43;
    address unitrollerContractAddress;
    address jumpRateModelV2ContractAddress;
    address oracleContractAddress;
    address timelockContractAddress;
    
    function run() external {
        address admin = 0xdA67F0F437D6067D441cCd4fCBd6ce93F1F0Df43; // multi-sig
        address guardian = 0xdA67F0F437D6067D441cCd4fCBd6ce93F1F0Df43;
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);


        // Deploy Timelock
        bytes memory timelockArgs = abi.encode(admin, 3 days);
        bytes memory bytecode = abi.encodePacked(vm.getCode("Timelock.sol:Timelock"), timelockArgs);
        address _timelockContractAddress;
        assembly {
            _timelockContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        timelockContractAddress = _timelockContractAddress;


        // Deploy Oracle
        bytecode = abi.encodePacked(vm.getCode("Oracle.sol:Oracle"));
        address _oracleContractAddress;
        assembly {
            _oracleContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        oracleContractAddress = _oracleContractAddress;


        // Deploy ComptrollerG6
        bytecode = abi.encodePacked(vm.getCode("ComptrollerG6.sol:ComptrollerG6"));
        address comptrollerContractAddress;
        assembly {
            comptrollerContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }


        // Deploy Unitroller
        bytecode = abi.encodePacked(vm.getCode("Unitroller.sol:Unitroller"));
        address _unitrollerContractAddress;
        assembly {
            _unitrollerContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        unitrollerContractAddress = _unitrollerContractAddress;


        IUnitroller unitroller = IUnitroller(unitrollerContractAddress);
        unitroller._setPendingImplementation(comptrollerContractAddress);

        IComptroller comptroller = IComptroller(comptrollerContractAddress);
        comptroller._become(unitrollerContractAddress);

        // configure unitroller - set price oracle & close factor
        unitroller._setPriceOracle(oracleContractAddress);
        unitroller._setCloseFactor(0.5e18); // 50%
        unitroller._setLiquidationIncentive(0.1e18); // 10%


        // Set Pause Guardian
        unitroller._setPauseGuardian(guardian);


        // Deploy Interest Model
        bytes memory rateModelArgs = abi.encode(0, 4e15, 15e16, 75e15, timelockContractAddress);
        bytecode = abi.encodePacked(vm.getCode("JumpRateModelV2.sol:JumpRateModelV2"), rateModelArgs);
        address _jumpRateModelV2ContractAddress;
        assembly {
            _jumpRateModelV2ContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        jumpRateModelV2ContractAddress = _jumpRateModelV2ContractAddress;


        // %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        // %%%%%%%%%%% MARKETS %%%%%%%%%%%
        // %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

        // Deploy coEth market 
        bytes memory coEtherArgs = abi.encode(unitrollerContractAddress, jumpRateModelV2ContractAddress, 2e26, "Cone Ether", "coEth", 8, deployer);
        bytecode = abi.encodePacked(vm.getCode("CEther.sol:CEther"), coEtherArgs);
        address coEtherContractAddress;
        assembly {
            coEtherContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        // Set coEth reserve factor
        ICToken(coEtherContractAddress)._setReserveFactor(0.2e18);


        // Set coEth market price feed
        address ethPriceFeed = 0xcD2A119bD1F7DF95d706DE6F2057fDD45A0503E2;
        IOracle oracle = IOracle(oracleContractAddress);
        oracle.setFeed(coEtherContractAddress, ethPriceFeed, 18);


        // Add coEth market to unitroller
        unitroller._supportMarket(coEtherContractAddress);


        // set coEth Collateral Factor
        unitroller._setCollateralFactor(coEtherContractAddress, 0.85e18);


        // Deploy Lens
        bytecode = abi.encodePacked(vm.getCode("CompoundLens.sol:CompoundLens"));
        address lensContractAddress;
        assembly {
            lensContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        // Deploy coUSDc market
        address usdcAddress = address(new Erc20Mock("USD Coin", "USDC", 6));
        deployErcMarket(usdcAddress, 2e14, "Cone USD Coin", "coUSDC", 0xb85765935B4d9Ab6f841c9a00690Da5F34368bc0, 0.85e18);

        
        // Upgrade ownership to timelock
        unitroller._setPendingAdmin(timelockContractAddress);
        oracle.changeOwner(timelockContractAddress);
        ICToken(coEtherContractAddress)._setPendingAdmin(payable(timelockContractAddress));
    }

    function deployErcMarket(
        address underlying,
        uint256 initialExchangeRate,
        string memory name,
        string memory symbol,
        address priceFeed,
        uint256 collateralFactor
    ) internal returns (address
    ) {
        // Deploy coErc2Immutable market
        bytes memory coErc2ImmutableArgs = abi.encode(underlying, unitrollerContractAddress, jumpRateModelV2ContractAddress, initialExchangeRate, name, symbol, 8, deployer);
        bytes memory bytecode = abi.encodePacked(vm.getCode("CErc20Immutable.sol:CErc20Immutable"), coErc2ImmutableArgs);
        address coErc2ImmutableContractAddress;
        assembly {
            coErc2ImmutableContractAddress := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        // Set coErc2Immutable reserve factor
        ICToken(coErc2ImmutableContractAddress)._setReserveFactor(0.2e18);

        // Set coErc2Immutable market price feed
        IOracle oracle = IOracle(oracleContractAddress);
        oracle.setFeed(coErc2ImmutableContractAddress, priceFeed, IErc20(underlying).decimals());

        // Add coErc2Immutable market to unitroller
        IUnitroller(unitrollerContractAddress)._supportMarket(coErc2ImmutableContractAddress);

        // set coErc2Immutable Collateral Factor
        IUnitroller(unitrollerContractAddress)._setCollateralFactor(coErc2ImmutableContractAddress, collateralFactor);

        // change ownership to timelock
        ICToken(coErc2ImmutableContractAddress)._setPendingAdmin(payable(timelockContractAddress));

        return coErc2ImmutableContractAddress;
    }

}


// forge script script/BaseGoerliCaster.s.sol:BaseGoerliCaster --rpc-url $GOERLI_BASE_RPC_URL --broadcast --verify $ETHERSCAN_API_KEY -vvvv
