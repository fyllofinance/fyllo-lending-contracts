pragma solidity ^0.5.16;

import "./ILiquidityGauge.sol";
import "./compound/Exponential.sol";
import "./Ownable.sol";

contract FylloConfig is Ownable, Exponential {
    address public compToken;
    uint256 public safetyVaultRatio = 0.01e18;
    address public safetyVault;
    address payable public safetyGuardian;
    address payable public pendingSafetyGuardian;

    struct MarketCap {
        /**
         *  The borrow capacity of the asset, will be checked in borrowAllowed()
         *  0 means there is no limit on the capacity
         */
        uint256 borrowCap;
        /**
         *  The supply capacity of the asset, will be checked in mintAllowed()
         *  0 means there is no limit on the capacity
         */
        uint256 supplyCap;
        /**
         *  The flash loan capacity of the asset, will be checked in flashLoanAllowed()
         *  0 means there is no limit on the capacity
         */
        uint256 flashLoanCap;
    }

    uint256 public compRatio = 0.5e18;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;
    mapping(address => MarketCap) marketsCap;
    // creditLimits allowed specific protocols to borrow and repay without collateral
    mapping(address => uint256) public creditLimits;
    uint256 public flashLoanFeeRatio = 0.0001e18;

    ILiquidityGauge public liquidityGauge;

    event NewCompToken(address oldCompToken, address newCompToken);
    event NewSafetyVault(address oldSafetyVault, address newSafetyVault);
    event NewSafetyVaultRatio(uint256 oldSafetyVaultRatio, uint256 newSafetyVault);

    event NewCompRatio(uint256 oldCompRatio, uint256 newCompRatio);
    event WhitelistChange(address user, bool enabled);
    event BlacklistChange(address user, bool enabled);
    /// @notice Emitted when protocol's credit limit has changed
    event CreditLimitChanged(address protocol, uint256 creditLimit);
    event FlashLoanFeeRatioChanged(uint256 oldFeeRatio, uint256 newFeeRatio);

    /// @notice Emitted when borrow cap for a cToken is changed
    event NewBorrowCap(address indexed cToken, uint256 newBorrowCap);

    /// @notice Emitted when supply cap for a cToken is changed
    event NewSupplyCap(address indexed cToken, uint256 newSupplyCap);

    /// @notice Emitted when flash loan for a cToken is changed
    event NewFlashLoanCap(address indexed cToken, uint256 newFlashLoanCap);

    event NewPendingSafetyGuardian(address oldPendingSafetyGuardian, address newPendingSafetyGuardian);

    event NewSafetyGuardian(address oldSafetyGuardian, address newSafetyGuardian);

    event NewLiquidityGauge(address oldLiquidityGauge, address newLiquidityGauage);

    modifier onlySafetyGuardian() {
        require(msg.sender == safetyGuardian, "Safety guardian required.");
        _;
    }

    constructor(FylloConfig _preCfg) public {
        safetyGuardian = msg.sender;
        if (address(_preCfg) == address(0)) return;

        safetyGuardian = _preCfg.safetyGuardian();
        compToken = _preCfg.compToken();
        safetyVaultRatio = _preCfg.safetyVaultRatio();
        safetyVault = _preCfg.safetyVault();
    }

    /**
     * @notice Set the given borrow caps for the given cToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param cTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        address[] calldata cTokens,
        uint256[] calldata newBorrowCaps
    ) external onlySafetyGuardian {
        uint256 numMarkets = cTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            marketsCap[cTokens[i]].borrowCap = newBorrowCaps[i];
            emit NewBorrowCap(cTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Set the given flash loan caps for the given cToken markets. Borrowing that brings total flash cap to or above flash loan cap will revert.
     * @dev Admin function to set the flash loan caps. A flash loan cap of 0 corresponds to unlimited flash loan.
     * @param cTokens The addresses of the markets (tokens) to change the flash loan caps for
     * @param newFlashLoanCaps The new flash loan cap values in underlying to be set. A value of 0 corresponds to unlimited flash loan.
     */
    function _setMarketFlashLoanCaps(
        address[] calldata cTokens,
        uint256[] calldata newFlashLoanCaps
    ) external onlySafetyGuardian {
        uint256 numMarkets = cTokens.length;
        uint256 numFlashLoanCaps = newFlashLoanCaps.length;

        require(numMarkets != 0 && numMarkets == numFlashLoanCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            marketsCap[cTokens[i]].flashLoanCap = newFlashLoanCaps[i];
            emit NewFlashLoanCap(cTokens[i], newFlashLoanCaps[i]);
        }
    }

    /**
     * @notice Set the given supply caps for the given cToken markets. Supplying that brings total supply to or above supply cap will revert.
     * @dev Admin function to set the supply caps. A supply cap of 0 corresponds to unlimited supplying.
     * @param cTokens The addresses of the markets (tokens) to change the supply caps for
     * @param newSupplyCaps The new supply cap values in underlying to be set. A value of 0 corresponds to unlimited supplying.
     */
    function _setMarketSupplyCaps(
        address[] calldata cTokens,
        uint256[] calldata newSupplyCaps
    ) external onlySafetyGuardian {
        uint256 numMarkets = cTokens.length;
        uint256 numSupplyCaps = newSupplyCaps.length;

        require(numMarkets != 0 && numMarkets == numSupplyCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            marketsCap[cTokens[i]].supplyCap = newSupplyCaps[i];
            emit NewSupplyCap(cTokens[i], newSupplyCaps[i]);
        }
    }

    /**
     * @notice Sets whitelisted protocol's credit limit
     * @param protocol The address of the protocol
     * @param creditLimit The credit limit
     */
    function _setCreditLimit(address protocol, uint256 creditLimit) public onlyOwner {
        require(isContract(protocol), "contract required");
        require(creditLimits[protocol] != creditLimit, "no change");

        creditLimits[protocol] = creditLimit;
        emit CreditLimitChanged(protocol, creditLimit);
    }

    function _setCompToken(address _compToken) public onlyOwner {
        address oldCompToken = compToken;
        compToken = _compToken;
        emit NewCompToken(oldCompToken, compToken);
    }

    function _setSafetyVault(address _safetyVault) public onlyOwner {
        address oldSafetyVault = safetyVault;
        safetyVault = _safetyVault;
        emit NewSafetyVault(oldSafetyVault, safetyVault);
    }

    function _setSafetyVaultRatio(uint256 _safetyVaultRatio) public onlySafetyGuardian {
        require(_safetyVaultRatio < 1e18, "!safetyVaultRatio");

        uint256 oldSafetyVaultRatio = safetyVaultRatio;
        safetyVaultRatio = _safetyVaultRatio;
        emit NewSafetyVaultRatio(oldSafetyVaultRatio, safetyVaultRatio);
    }

    function _setPendingSafetyGuardian(address payable newPendingSafetyGuardian) external onlyOwner {
        address oldPendingSafetyGuardian = pendingSafetyGuardian;
        pendingSafetyGuardian = newPendingSafetyGuardian;

        emit NewPendingSafetyGuardian(oldPendingSafetyGuardian, newPendingSafetyGuardian);
    }

    function _acceptSafetyGuardian() external {
        require(msg.sender == pendingSafetyGuardian, "!pendingSafetyGuardian");

        address oldPendingSafetyGuardian = pendingSafetyGuardian;
        address oldSafetyGuardian = safetyGuardian;
        safetyGuardian = pendingSafetyGuardian;
        pendingSafetyGuardian = address(0);

        emit NewSafetyGuardian(oldSafetyGuardian, safetyGuardian);
        emit NewPendingSafetyGuardian(oldPendingSafetyGuardian, pendingSafetyGuardian);
    }

    function getCreditLimit(address protocol) external view returns (uint256) {
        return creditLimits[protocol];
    }

    function getBorrowCap(address cToken) external view returns (uint256) {
        return marketsCap[cToken].borrowCap;
    }

    function getSupplyCap(address cToken) external view returns (uint256) {
        return marketsCap[cToken].supplyCap;
    }

    function getFlashLoanCap(address cToken) external view returns (uint256) {
        return marketsCap[cToken].flashLoanCap;
    }

    function calculateSeizeTokenAllocation(
        uint256 _seizeTokenAmount,
        uint256 liquidationIncentiveMantissa
    ) public view returns (uint256 liquidatorAmount, uint256 safetyVaultAmount) {
        Exp memory vaultRatio = Exp({mantissa: safetyVaultRatio});
        Exp memory tmp = mul_(vaultRatio, _seizeTokenAmount);
        safetyVaultAmount = div_(tmp, liquidationIncentiveMantissa).mantissa;
        liquidatorAmount = sub_(_seizeTokenAmount, safetyVaultAmount);
    }

    function getCompAllocation(
        address user,
        uint256 userAccrued
    ) public view returns (uint256 userAmount, uint256 governanceAmount) {
        if (!isContract(user) || whitelist[user]) {
            return (userAccrued, 0);
        }

        Exp memory compRatioExp = Exp({mantissa: compRatio});
        userAmount = mul_ScalarTruncate(compRatioExp, userAccrued);
        governanceAmount = sub_(userAccrued, userAmount);
    }

    function getFlashFee(address borrower, address cToken, uint256 amount) external view returns (uint256 flashFee) {
        if (whitelist[borrower]) {
            return 0;
        }
        Exp memory flashLoanFeeRatioExp = Exp({mantissa: flashLoanFeeRatio});
        flashFee = mul_ScalarTruncate(flashLoanFeeRatioExp, amount);

        cToken;
    }

    function _setCompRatio(uint256 _compRatio) public onlySafetyGuardian {
        require(_compRatio < 1e18, "compRatio should be less then 100%");
        uint256 oldCompRatio = compRatio;
        compRatio = _compRatio;

        emit NewCompRatio(oldCompRatio, compRatio);
    }

    function isBlocked(address user) public view returns (bool) {
        return blacklist[user];
    }

    function _addToWhitelist(address _member) public onlySafetyGuardian {
        require(_member != address(0), "Zero address is not allowed");
        whitelist[_member] = true;

        emit WhitelistChange(_member, true);
    }

    function _removeFromWhitelist(address _member) public onlySafetyGuardian {
        require(_member != address(0), "Zero address is not allowed");
        whitelist[_member] = false;

        emit WhitelistChange(_member, false);
    }

    function _addToBlacklist(address _member) public onlySafetyGuardian {
        require(_member != address(0), "Zero address is not allowed");
        blacklist[_member] = true;

        emit BlacklistChange(_member, true);
    }

    function _removeFromBlacklist(address _member) public onlySafetyGuardian {
        require(_member != address(0), "Zero address is not allowed");
        blacklist[_member] = false;

        emit BlacklistChange(_member, false);
    }

    function _setFlashLoanFeeRatio(uint256 _feeRatio) public onlySafetyGuardian {
        require(_feeRatio != flashLoanFeeRatio, "Same fee ratio already set");
        require(_feeRatio < 1e18, "Invalid fee ratio");

        uint256 oldFeeRatio = flashLoanFeeRatio;
        flashLoanFeeRatio = _feeRatio;

        emit FlashLoanFeeRatioChanged(oldFeeRatio, flashLoanFeeRatio);
    }

    function _setliquidityGauge(ILiquidityGauge _liquidityGauge) external onlySafetyGuardian {
        emit NewLiquidityGauge(address(liquidityGauge), address(_liquidityGauge));

        liquidityGauge = _liquidityGauge;
    }

    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
