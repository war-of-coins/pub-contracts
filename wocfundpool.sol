// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { ActionNonceType, TokenPrecision } from "./wocauxer.sol";

interface WocAuxer {
    function convertToExtFundAmount(uint64 _amount, uint8 _fundDecimals) external pure returns (uint256);
}

/**
 * @title Woc Fund Pool
 * @dev This contract handles the woc fund pool and management.
 */
contract WocFundPool is Initializable, OwnableUpgradeable {
    struct FundPoolParams {
        uint64 minPoolAmount;       
        uint64 maxPoolAmount;       
        uint64 minStakingAmount;     
        uint64 maxStakingAmount; 
    }

    struct StakedFund {
        uint64 fundUnits;
        uint64 avgPrice;
        uint64 pendingWithdrawUnits; 
	}
    
    struct DividendInfo {
        uint64 accuPurchase;
        uint64 loss;
        uint64 revenue;
        uint64 warcRewards;
        uint32 lastDividendTime;
        uint32 nextDividendTime;
    }

    struct DividendParams {
        uint32 LPRatio;
        uint32 LPCashRatio;
        uint32 MLMRatio;
        uint32 OPRatio;
        uint32 LPMiningRatio;
    }

    struct PendingStaking {
        address lp;
        uint64 amount;
    }

    struct PendingWithdraw {
        address lp;
        uint64 units;
    }

    event LPStakeRequest(
        address indexed lp,
        uint32 index,
        bytes16 fundName,
        uint64 amount
    );

    event LPStakeFund(
        address indexed lp,
        uint32 index,
        bytes16 fundName,
        uint64 amount,
        uint64 remaining,
        uint64 fundUnit
    );

    event LPWithdrawRequest(
        address indexed lp,
        uint32 index,
        bytes16 fundName,
        uint64 units
    );

    event LPWithdrawFund(
        address indexed lp,
        uint32 index,
        bytes16 fundName,
        uint64 amount,
        uint64 units
    );

    event LPSessionResult(
        uint32 indexed session,
        bytes16 fund,
        uint64 revenue,
        uint64 loss,
        uint64 deficit,
        uint64 warcRewards,
        uint64 accuPurchase,
        uint64 poolRevenue,
        uint64 poolLoss,
        uint64 fundUnitPrice
    );

    event PoolPendingActions(
        uint32 indexed scheduledDividendTime,
        bytes16 fund,
        uint64 currentPoolBalance,
        uint64 totalFundUnits, 
        uint64 totalLps, 
        uint64 fundPrice,
        uint64 totalWithdrawUnits,
        uint64 totalWithdrawAmount,
        uint64 totalPendingStakingAmount,
        uint64 totalStakingAmount,
        uint64 totalLpAmount
    );

    event LPDividend(
        uint32 indexed scheduledDividendTime,
        bytes16 fund,
        uint64 currentPoolBalance,
        uint64 loss,
        uint64 revenue, 
        uint64 opincome, 
        uint64 mlmCashDividend,
        uint64 lpCashDividend,
        uint64 accuPurchase,
        uint64 totalFundUnits,
        uint64 warcRewards
    );

    FundPoolParams fundPoolParams;
    DividendParams dividendParams;
    DividendInfo dividendInfo;
    
    PendingStaking[] pendingStakings;
    PendingWithdraw[] pendingWithdraws;
    mapping(bytes16 => uint32) sessionFundPcts;
    mapping(address => StakedFund) fundPool;
    mapping(bytes32 => uint64) assetSessionFund;
   
    address public wocMain;            
    address public fundERC20;
    address public wocAuxer;
    address public wocVault;
    address public oracle;
    address public operator;
    uint8 fundDecimals;
    bool isPoolActive;
    bool allowPoolAction;
    bytes16 fundName;

    uint64 currentPoolBalance;	
    uint64 totalFundUnits;
    uint64 fundUnitPrice;	
    uint64 allocatedSessionFund;
    
    uint64 totalLpCashDividend;
    uint64 totalMlmCashDividend;
    uint32 currentLPs;
    uint32 activeSessions; 

    uint64 totalPendingStakingAmount;
    uint64 totalPendingWithdrawUnits;
    uint64 totalWarcRewards;
    uint32 maxPoolLossRatio;
    uint64 totalReplenish;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _funderc20, bytes16 _fundName, uint8 _fundDecimals, address _wocvault, address _wocauxer, address _oracle) public initializer {
        __Ownable_init();
        fundERC20 = _funderc20;
        wocVault = _wocvault;
        wocAuxer = _wocauxer;
        oracle = _oracle;
        fundDecimals = _fundDecimals > 0? _fundDecimals : ERC20Upgradeable(fundERC20).decimals();
        fundName = _fundName;
        require(fundDecimals > TokenPrecision, "fundDecimals not supported");
        fundUnitPrice = uint64(10**TokenPrecision);
        allowPoolAction = true;
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
    }

    function initConfig(address _wocMain, address _operator) external onlyOwner {
        wocMain = _wocMain;
        operator = _operator;
    }

    function getFundInfo() external view returns (address, uint8, bytes16) {
        return (fundERC20, fundDecimals, fundName);
    }

    function activatePool(uint32 _nextDividendTime) external onlyOwner {
        require(wocMain != address(0) && operator != address(0), "unable to activate");
        require(currentPoolBalance >= fundPoolParams.minPoolAmount, "pool balance less than minimum");
        require(activeSessions == 0, "active sessions existing");
        require(totalPendingStakingAmount == 0 && totalPendingWithdrawUnits == 0 && dividendInfo.accuPurchase == 0, "pending dividend");
        isPoolActive = true;
        internalSetNextDividendTime(_nextDividendTime);
    }

    function getPoolStatus() external view returns (bool active, bool allowLpAction, uint32 nextDividendTime) {
        return (isPoolActive, allowPoolAction, dividendInfo.nextDividendTime);
    }

    function setAllowPoolAction(bool _allow) external onlyOwner {
        allowPoolAction = _allow;
    }

    function setPoolActive(bool _active) external onlyOwner {
        isPoolActive = _active;
    }

    function setNextDividendTime(uint32 _nextDividendTime) external onlyOwner {
        internalSetNextDividendTime(_nextDividendTime);
    }
    
    function internalSetNextDividendTime(uint32 _nextDividendTime) internal returns (uint32 scheduledDividendTime) {
        require(_nextDividendTime > uint32(block.timestamp) + 7200, "nextDividend time invalid");
        scheduledDividendTime = dividendInfo.nextDividendTime;
        dividendInfo.nextDividendTime = _nextDividendTime;
    }

    function setAssetSessionFundPortion(bytes16 _asset, uint32 _percent) external onlyOwner {
        require(_percent > 0 && _percent < 100, "invalid percentage");
        sessionFundPcts[_asset] = _percent;
    }

    function getAssetSessionFundPortion(bytes16 _asset) external view returns (uint32 percnt) {
        return sessionFundPcts[_asset];
    }

    function getDividendParams() external view returns (
        uint32 lpCashRatio,
        uint32 lpRatio,
        uint32 mlmRatio,
        uint32 opRatio,
        uint32 lpMiningRatio
    ) {
        return (dividendParams.LPCashRatio, dividendParams.LPRatio, dividendParams.MLMRatio, dividendParams.OPRatio, dividendParams.LPMiningRatio);
    }

    function setDividendParams(uint32 _LPCashRatio, uint32 _LPRatio, uint32 _MLMRatio, uint32 _OPRatio, uint32 _LPMiningRatio) public onlyOwner {
        require(_LPCashRatio < 100 && _LPRatio < 100 && _MLMRatio < 100 && _OPRatio < 100 && _LPMiningRatio < 100, "invalid dividend params");
        require((_LPCashRatio + _LPRatio + _MLMRatio + _OPRatio) == 100, "invalid total dividend");
        dividendParams.LPCashRatio = _LPCashRatio;
        dividendParams.LPRatio = _LPRatio;
        dividendParams.MLMRatio = _MLMRatio;
        dividendParams.OPRatio = _OPRatio;
        dividendParams.LPMiningRatio = _LPMiningRatio;
    }

    function getFundPoolParams() external view returns (
        uint64 minPoolAmount,
        uint64 maxPoolAmount, 
        uint64 minStakingAmount, 
        uint64 maxStakingAmount,
        uint64 maxLossRatio
    ) {
        return (
            fundPoolParams.minPoolAmount,
            fundPoolParams.maxPoolAmount, 
            fundPoolParams.minStakingAmount,
            fundPoolParams.maxStakingAmount,
            maxPoolLossRatio
        );
    }  

    function setMaxPoolLossRatio(uint32 _maxLossRatio) public onlyOwner {
        require(_maxLossRatio > 0 && _maxLossRatio < 100, "invalid max loss ratio");
        maxPoolLossRatio = _maxLossRatio;  
    }

    function setFundPoolParams(uint64 _minPoolAmount, uint64 _maxPoolAmount, uint64 _minStakingAmount, uint64 _maxStakingAmount) public onlyOwner {
        fundPoolParams.minPoolAmount = _minPoolAmount;
        fundPoolParams.maxPoolAmount = _maxPoolAmount;
        fundPoolParams.minStakingAmount = _minStakingAmount;
        fundPoolParams.maxStakingAmount = _maxStakingAmount;
    }

    function getPoolInfo() external view returns (
         uint64 poolBalance, 
         uint32 sessions, 
         uint64 sessionFund, 
         uint64 fundUnits, 
         uint64 unitPrice, 
         uint64 cashDividend,
         uint64 mlmDividend,
         uint32 numofLPs,
         uint64 warcRewards
    ) {
        return (currentPoolBalance, activeSessions, allocatedSessionFund, totalFundUnits, fundUnitPrice, totalLpCashDividend, totalMlmCashDividend, currentLPs, totalWarcRewards);
    }

    function staking(uint64 _amount, bytes16 _fund) external {
        require(allowPoolAction, "305:Pool action paused");
        require(_fund == fundName, "307:invalid fund");
        require(_amount >= fundPoolParams.minStakingAmount && _amount <= fundPoolParams.maxStakingAmount, "301:Staking amount exceeds limit");
        uint64 realAmount;
        address lp = _msgSender();
        if (isPoolActive) {
            require(block.timestamp + 7200 <= dividendInfo.nextDividendTime, "302:Pool action paused for dividend");
            addPendingStaking(lp, _amount);
            realAmount = _amount;
        }
        else {
            (realAmount, ) = stakingAmount(lp, _amount, 0);
            require(realAmount > 0, "303:Exceed max pool amount limit");
        }
        SafeERC20Upgradeable.safeTransferFrom(
            IERC20Upgradeable(fundERC20),
            lp,
            address(this),
            WocAuxer(wocAuxer).convertToExtFundAmount(realAmount, fundDecimals)
        );
    }

    function stakingAmount(address lp, uint64 amount, uint32 index) internal returns (uint64 realAmount, uint64 remaining) {
        uint64 lpUnits = amount / fundUnitPrice;
        remaining = amount % fundUnitPrice;
        realAmount = amount - remaining;
        if (currentPoolBalance + realAmount > fundPoolParams.maxPoolAmount) {
            realAmount = 0;
            remaining = amount;
        }
        else {
            StakedFund storage stakedFund = fundPool[lp];
            if (stakedFund.fundUnits == 0) {
                currentLPs++;
            }
            uint64 currentStaking = stakedFund.fundUnits * stakedFund.avgPrice;
            stakedFund.fundUnits += lpUnits;
            stakedFund.avgPrice = (currentStaking + realAmount) / stakedFund.fundUnits;
            totalFundUnits += lpUnits;
            currentPoolBalance += realAmount;
        }

        emit LPStakeFund(
            lp,
            index,
            fundName,
            realAmount,
            index > 0? remaining : 0,    // direct staking has no remaining
            lpUnits
        );
    }

    function addPendingStaking(address lp, uint64 _amount) internal {
        pendingStakings.push(PendingStaking(lp, _amount));
        totalPendingStakingAmount += _amount;
        emit LPStakeRequest(
            lp,
            uint32(pendingStakings.length),
            fundName,
            _amount
        );
    }

    function withdraw(uint64 _units, bytes16 _fund) external {
        require(_units > 0, "304:Invalid withdraw request");
        require(allowPoolAction, "305:Pool action paused");
        require(_fund == fundName, "307:invalid fund");
        address lp = _msgSender();
        StakedFund storage fundInfo = fundPool[lp];
        if (isPoolActive) {
            require(block.timestamp + 7200 <= dividendInfo.nextDividendTime, "302:Pool action paused for dividend");
            require(fundInfo.fundUnits - fundInfo.pendingWithdrawUnits >= _units, "304:Invalid withdraw request");
            addPendingWithdraw(lp, _units);
        }
        else {
            require(fundInfo.fundUnits >= _units, "304:Invalid withdraw request");
            uint64 amount = withdrawUnits(lp, _units, 0);
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(fundERC20),
                lp,
                WocAuxer(wocAuxer).convertToExtFundAmount(amount, fundDecimals)
            );
        }
    }

    function addPendingWithdraw(address lp, uint64 _units) internal {
        pendingWithdraws.push(PendingWithdraw(lp, _units));
        fundPool[lp].pendingWithdrawUnits += _units;
        totalPendingWithdrawUnits += _units;
        emit LPWithdrawRequest(
            lp,
            uint32(pendingWithdraws.length),
            fundName,
            _units
        );
    }

    function withdrawUnits(address lp, uint64 _units, uint32 _pendingIndex) internal returns (uint64 amount) {
        amount = _units * fundUnitPrice;
        StakedFund storage fundInfo = fundPool[lp];
        fundInfo.fundUnits -= _units;
        if (_pendingIndex > 0) fundInfo.pendingWithdrawUnits -= _units;
        currentPoolBalance -= amount;
        totalFundUnits -= _units;
        
        emit LPWithdrawFund(
            lp,
            _pendingIndex,
            fundName,
            amount,
            _units
        );

        if (fundInfo.fundUnits == 0) {
            delete fundPool[lp];
            currentLPs--;
        } 
    }

    function getStakeInfo(address _addr) external view returns (
        uint64 fundUnits, 
        uint64 avgPrice, 
        uint64 pendingWithdrawUnits
    ) {
        StakedFund storage fundInfo = fundPool[_addr];
        return (fundInfo.fundUnits, fundInfo.avgPrice, fundInfo.pendingWithdrawUnits);
    }

    function getPendingPoolActionInfo() external view returns (
        uint64 pendingStakingAmount,
        uint64 pendingStakingNum,
        uint64 pendingWithdrawUnits,
        uint64 pendingWithdrawsNum
    ) {
        return (
                totalPendingStakingAmount, 
                uint64(pendingStakings.length),
                totalPendingWithdrawUnits,
                uint64(pendingWithdraws.length)
                );
    }
    
    function allocateSessionFund(bytes16 _asset, uint32 _session) external onlyWocMain returns (uint64) {
        if (isPoolActive == false) return 0;
        uint32 sessionFundPercentage = sessionFundPcts[_asset];
        require(sessionFundPercentage > 0, "asset not configured");
        bytes32 assetSessionKey = bytes32(bytes.concat(_asset, bytes16(uint128(_session))));
        require(assetSessionFund[assetSessionKey] == 0, "session already exists");
        
        uint64 availableFund = currentPoolBalance - dividendInfo.loss;
        if (_session > dividendInfo.nextDividendTime) { // cross dividend cycle 
            uint64 pendingWithdrawAmount = availableFund * totalPendingWithdrawUnits / totalFundUnits;
            availableFund = availableFund + totalPendingStakingAmount - pendingWithdrawAmount;
        }

        if (availableFund < fundPoolParams.minPoolAmount) {
            isPoolActive = false;
            allowPoolAction = false;
            return 0;   // stop allocating fund for new session
        }

        uint64 fund = uint64((availableFund * sessionFundPercentage / 100)
                        / 10 ** TokenPrecision * 10 ** TokenPrecision);
        assetSessionFund[assetSessionKey] = fund;
        allocatedSessionFund += fund;
        activeSessions++;

        SafeERC20Upgradeable.safeTransfer(
            IERC20Upgradeable(fundERC20),
            wocMain,
            WocAuxer(wocAuxer).convertToExtFundAmount(fund, fundDecimals)
        ); 
        return fund;
    }

    //balanceOf(pool) = currentpoolbalance + dividendInfo.revenue - dividendInfo.loss - allocatedSessionFund + totalPendingStaking
    function sessionResult(bytes16[] calldata _assets, uint32 _session, uint64 _initialFund, uint64 _volume, uint64 _payout, uint64 _warcRewards) onlyWocMain external {
        for (uint i = 0; i < _assets.length; i++) {
            bytes32 assetSessionKey = bytes32(bytes.concat(_assets[i], bytes16(uint128(_session))));
            require(assetSessionFund[assetSessionKey] > 0, "invalid session result");
            allocatedSessionFund -= assetSessionFund[assetSessionKey];
            delete assetSessionFund[assetSessionKey];
            activeSessions--;
        }
        dividendInfo.warcRewards += _warcRewards;
        dividendInfo.accuPurchase += _volume;
        
        uint64 revenue;
        uint64 loss;
        if (_volume > _payout) revenue = _volume - _payout;
        else loss = _payout - _volume;
        
        if (revenue > 0) {
            if (dividendInfo.loss > revenue) {
                dividendInfo.loss -= revenue;
            }
            else {
                dividendInfo.revenue += (revenue - dividendInfo.loss);
                dividendInfo.loss = 0;
            } 
        } 
        if (loss > 0) {
            if (loss <= dividendInfo.revenue) {
                dividendInfo.revenue -= loss;
            }
            else {
                dividendInfo.loss += (loss - dividendInfo.revenue);
                dividendInfo.revenue = 0;
            }
        }
        uint64 deficit;
        if (_payout > _initialFund + _volume) {
            // transfer session deficit to main contract
            deficit = _payout - _initialFund - _volume;
            require(deficit < _initialFund, "invalid deficit");
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(fundERC20),
                wocMain,
                WocAuxer(wocAuxer).convertToExtFundAmount(deficit, fundDecimals)
            ); 
        }
        if (deficit > 0 || dividendInfo.loss >= currentPoolBalance * maxPoolLossRatio / 100) {
            isPoolActive = false; // stop new session
            allowPoolAction = false; // stop staking/withdraw 
        }

        if (revenue != loss) {
             // LP unit price = (Current fund + Revenue * LP revenue sharing pct) / LP units
            fundUnitPrice = (currentPoolBalance - dividendInfo.loss 
                                + dividendInfo.revenue * dividendParams.LPRatio / 100
                            ) / totalFundUnits;
        }
        
        emit LPSessionResult(
            _session,
            fundName,
            revenue,
            loss,
            deficit,
            _warcRewards,
            dividendInfo.accuPurchase,
            dividendInfo.revenue,
            dividendInfo.loss,
            fundUnitPrice
        );
    }
    
    function dividend(uint32 _nextDividendTime) onlyOracle external {
        require(dividendInfo.lastDividendTime < block.timestamp, "dividend reentrant");
        dividendInfo.lastDividendTime = uint32(block.timestamp);
        uint32 scheduledDividendTime = internalSetNextDividendTime(_nextDividendTime);

        currentPoolBalance -= dividendInfo.loss;
        uint64 lpCashDividend;
        uint64 mlmCashDividend;
        uint64 opincome;
        if (dividendInfo.revenue > 0) {
            opincome = dividendInfo.revenue * dividendParams.OPRatio / 100;
            lpCashDividend = dividendInfo.revenue * (dividendParams.LPCashRatio) / 100;
            mlmCashDividend = dividendInfo.revenue * (dividendParams.MLMRatio) / 100;
            currentPoolBalance += (dividendInfo.revenue 
                                    - opincome
                                    - lpCashDividend
                                    - mlmCashDividend);  // do not use LPRatio to avoid rounddown gap
        
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(fundERC20),
                operator, 
                WocAuxer(wocAuxer).convertToExtFundAmount(opincome, fundDecimals)
            ); 
            
            totalLpCashDividend += lpCashDividend;
            totalMlmCashDividend += mlmCashDividend;
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(fundERC20),
                wocVault,
                WocAuxer(wocAuxer).convertToExtFundAmount(lpCashDividend + mlmCashDividend, fundDecimals)
            ); 
        }
        uint64 miningWarc = dividendInfo.warcRewards * dividendParams.LPMiningRatio / 100;
        totalWarcRewards += miningWarc;
        emit LPDividend(
            scheduledDividendTime,
            fundName,
            currentPoolBalance,
            dividendInfo.loss,
            dividendInfo.revenue, 
            opincome,
            mlmCashDividend,
            lpCashDividend,
            dividendInfo.accuPurchase,      
            totalFundUnits,                 
            miningWarc
        );  
        dividendInfo.loss = 0;
        dividendInfo.revenue = 0;
        dividendInfo.accuPurchase = 0;
        dividendInfo.warcRewards = 0;

        processPendingLpActions(scheduledDividendTime);
        if (activeSessions == 0 && !allowPoolAction) {
            allowPoolAction = true;
        }
    } 

    function processPendingLpActions(uint32 _scheduledDividendTime) internal {
        uint withdraws = pendingWithdraws.length;
        uint64 totalWithdrawAmount;
        for (uint32 i = 0; i < withdraws; ++i) {
            uint64 amount = withdrawUnits(pendingWithdraws[i].lp, pendingWithdraws[i].units, i+1);
            totalWithdrawAmount += amount;
        }
        delete pendingWithdraws;

        uint stakings = pendingStakings.length;
        uint64 totalStakingRemaining;
        uint64 totalStakingAmount;
        for (uint32 i = 0; i < stakings; ++i) {
            (uint64 realAmount, uint64 remaining) = stakingAmount(pendingStakings[i].lp, pendingStakings[i].amount, i+1);
            totalStakingRemaining += remaining;
            totalStakingAmount += realAmount;
        }
        delete pendingStakings;
        
        uint64 totalLpOutAmount = totalWithdrawAmount + totalStakingRemaining;
        if ( totalLpOutAmount > 0) { // transfer fund to wocVault for individual withdraw
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(fundERC20),
                wocVault,
                WocAuxer(wocAuxer).convertToExtFundAmount(totalLpOutAmount, fundDecimals)
            ); 
        }

        emit PoolPendingActions(
            _scheduledDividendTime,
            fundName,
            currentPoolBalance,
            totalFundUnits,
            currentLPs,
            fundUnitPrice,
            totalPendingWithdrawUnits,
            totalWithdrawAmount,
            totalPendingStakingAmount,
            totalStakingAmount,
            totalLpOutAmount
        );

        totalPendingWithdrawUnits = totalPendingStakingAmount = 0;
    }

    function getDividendInfo() external view returns (
        uint64 accuPurchase,
        uint64 loss,
        uint64 revenue,
        uint64 warcRewards,
        uint32 lastDividendTime,
        uint32 nextDividendTime
    ) {
        return (
            dividendInfo.accuPurchase,
            dividendInfo.loss,
            dividendInfo.revenue,
            dividendInfo.warcRewards,
            dividendInfo.lastDividendTime,
            dividendInfo.nextDividendTime
        );
    } 

    function getPoolBalance() external view returns (uint64 balance) {
        return currentPoolBalance - allocatedSessionFund 
               + dividendInfo.revenue - dividendInfo.loss 
               + totalPendingStakingAmount;
    }

    event Replenish(
        address sender,
        uint64 amount,
        uint64 poolBalance
    );

    function treasuryReplenish(uint64 _amount) external {
        address sender = _msgSender();
        SafeERC20Upgradeable.safeTransferFrom(
            IERC20Upgradeable(fundERC20),
            sender,
            address(this),
            WocAuxer(wocAuxer).convertToExtFundAmount(_amount, fundDecimals)
        );
        currentPoolBalance += _amount;
        totalReplenish += _amount;
        emit Replenish(_msgSender(), _amount, currentPoolBalance);
    }

    modifier onlyOracle {
        require(_msgSender() == oracle, "invalid caller");
        _;
    }

    modifier onlyWocMain {
        require(_msgSender() == wocMain, "unregistered wocmain");
        _;
    }    
}
