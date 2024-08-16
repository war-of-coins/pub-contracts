// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { ActionNonceType, TokenPrecision } from "./wocauxer.sol";

interface WocAuxer {
    function verifyMessage(
        ActionNonceType _type,
        address _addr,
        uint256 _effectiveTime,
        uint256 _nonce,
        bytes memory _message,
        bytes memory _signature
    ) external;
    function convertToExtFundAmount(uint64 _amount, uint8 _fundDecimals) external pure returns (uint256);
}

interface WocFundPool {
    function allocateSessionFund(bytes16 _asset, uint32 _session) external returns (uint64);
    function sessionResult(bytes16[] calldata _assets, uint32 _session, uint64 _fund, uint64 _volume, uint64 _payout, uint64 _warcRewards) external;
    function getFundInfo() external view returns (address, uint8, bytes16);
}

/**
 * @title WarcMain
 * @dev This contract handles the option purchase and drawing.
 * the contract hold user balance of winning payout (U or other LP fund type) 
 * this contract is deployed together with wocfundpool 
 * for each LP token type on each chain. 
 * i.e. set of contracts for 1. USDT on ethereum, 2. WARC on BSC, 3. USDT on BSC etc.    
 */
contract WarofCoinsMain is Initializable, OwnableUpgradeable {
    uint32 constant maxOrdersPerSession = 10 ** 6; // max 1m orders per session

    struct OrderInfo {  
        address user;
        bool long;
        bool exercised;
        uint64 amount;
        uint32 maxPayoutIdx;         
        uint32[7] pricePoints;
    }
    
    struct WocConfig {
        uint64 maxOrderSize;
        uint64 minOrderSize;
        uint32 maxPayoutIdx;
        uint32 dirFundRatio; // session fund ratio for each direction (call/put) 
    }

    struct SessionInfo { 
        uint32 id;     
        uint32 maxPayoutIdx;       
        uint64[7] slotUnits;
        uint64 totalUnits;      
        uint64 issuedWarcReward;
        uint64 totalLong;
        uint64 totalShort;
        uint64 totalExPayout; 
        uint64 sessionFund;
        OrderInfo[] orders; 
    } 

    struct SessionContainer {   
        mapping(uint32 => SessionInfo) info;
        uint32[] sessionIds;
    }

    struct WarcRewardSetting {
        uint64 sessionRewardMax; 
        uint64[] salesRanks;
        uint32[] rewardRatios;   
    }

    struct SessionResult {
        uint64 totalFund;
        uint64 totalPurchase;
        uint64 totalExPayout;
        uint64 totalDrawPayout;
        uint64 warcReward;
        uint64 totalDrawPurchase;
    }

    event Order(
        address indexed user,
        bytes16 indexed asset,
        uint32 indexed session, 
        uint32 orderId,
        bytes16 fundName,
        uint64 amount, 
        uint64 localAmount,
        uint64 warcReward, 
        uint32[7] pricePoints,
        bool long, 
        uint32 maxPayout,
        uint64 remainingUnits
    );

    event SessionSummary(
        bytes16 indexed asset,
        uint32 indexed session,
        bytes16 fundName, 
        uint32 strikeprice,
        uint64 totalLong, 
        uint64 totalShort, 
        uint32 totalOrders, 
        uint64 totalReward,
        uint64 totalExPayout,
        uint64 exMaturePayout,
        uint64 maturePayout
    );

    event UserBalanceWithdraw(
        address indexed user, 
        bytes16 fundName,
        uint64 amount
    );

    event Exercise(
        address indexed user, 
        bytes16 indexed asset,
        uint32 indexed session, 
        uint32 orderId,
        bytes16 fundName,
        uint32 returnRatio, 
        uint64 exPrice,
        uint64 payout 
    );

    event ConfigChange(
        uint64 maxOrderSize,
        uint64 minOrderSize,
        uint32 maxPayoutIdx,
        bytes16 fundName
    );

    WocConfig wocConfig;
    WarcRewardSetting rewardSetting;
    mapping(bytes16 => SessionContainer) assetSessions;     
    
    address public wocAuxer;
    address public fundPool;        
    address public oracle;
    address public fundERC20;       
    uint8 fundDecimals;
    bytes16 fundName;
    
    uint64 totalWarcRewards;       
    uint64 totalUserBalance;          
    uint64 totalUnresolvedPurchase;
    uint64 currentSessionFund;
    // /// @custom:oz-renamed-from reserveUint64
    uint64 currentExPayout;   
    uint32[7] payoutTable;
    uint32[7] fundPortion;
    uint64 currentExPurchase;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _fundPool, address _wocauxer, address _oracle) public initializer {
        __Ownable_init();
        fundPool = _fundPool;
        wocAuxer = _wocauxer;
        oracle = _oracle;
        (fundERC20, fundDecimals, fundName) = WocFundPool(fundPool).getFundInfo();
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
    }

    function setPayoutTable(uint32 _maxPayoutIdx, uint32[7] calldata _payoutTable, uint32[7] calldata _fundPortion) external onlyOwner {
        require(_maxPayoutIdx < payoutTable.length && _maxPayoutIdx > 0, "invalid maxPayoutId");
        require(_payoutTable.length == _fundPortion.length, "inconsistent fundportion");
        require(_payoutTable[0] == 1, "first payout must be 1"); 
        uint32 totalPortion = 0;
        for (uint i = 0; i <= _maxPayoutIdx; i++) {
            require(_payoutTable[i] > 0, "Invalid payout");
            totalPortion += _fundPortion[i];
        }
        require(totalPortion == 10000, "invalid fundportion");
        payoutTable = _payoutTable;
        fundPortion = _fundPortion;
        wocConfig.maxPayoutIdx = _maxPayoutIdx;
        emit ConfigChange(wocConfig.minOrderSize, wocConfig.maxOrderSize, wocConfig.maxPayoutIdx, fundName);
    }

    function getPayoutTable() external view returns (uint32 maxPayout, uint32[7] memory payouts, uint32[7] memory fundportion) {
        return (payoutTable[wocConfig.maxPayoutIdx], payoutTable, fundPortion);
    }

    function setRewardSettings(uint64[] calldata _salesRanks, uint32[] calldata _rewardRatios, uint64 _sessionRewardMax) public onlyOwner {
        require(_salesRanks.length == _rewardRatios.length);
        uint len = _salesRanks.length;
        delete rewardSetting.salesRanks;
        delete rewardSetting.rewardRatios;
        for (uint i = 0; i < len; i++) {
            rewardSetting.salesRanks.push(_salesRanks[i]);
            rewardSetting.rewardRatios.push(_rewardRatios[i]);
        }
        rewardSetting.sessionRewardMax = _sessionRewardMax;
    }
    
    function getRewardSetting() external view 
    returns (
        uint64 sessionMaxReward, 
        uint64[] memory salesRank, 
        uint32[] memory rewardRatio
    ) {
        return (rewardSetting.sessionRewardMax, 
                rewardSetting.salesRanks,
                rewardSetting.rewardRatios);
    }

    function setWocConfig(uint64 _minOrderSize, uint64 _maxOrderSize, uint32 _dirFundRatio) public onlyOwner {
        require(_minOrderSize < _maxOrderSize, "invalid mix/max order size");
        require(_dirFundRatio > 0 && _dirFundRatio <= 100, "invalid dirFundRatio");
        wocConfig.minOrderSize = _minOrderSize;    
        wocConfig.maxOrderSize = _maxOrderSize; 
        wocConfig.dirFundRatio = _dirFundRatio;
        emit ConfigChange(wocConfig.minOrderSize, wocConfig.maxOrderSize, wocConfig.maxPayoutIdx, fundName);
    }

    function getWocConfig() external view returns (uint64, uint64, uint32, uint32) {
        return (wocConfig.maxOrderSize, wocConfig.minOrderSize, wocConfig.maxPayoutIdx, wocConfig.dirFundRatio);
    }

    function initSessions(bytes16 _asset, uint32 _session) external onlyOwner {
        require(assetSessions[_asset].sessionIds.length == 0, "already inited");
        require(_session % 3600 == 0 && _session > (uint32(block.timestamp) + 3600), "invalid init session");
        if (createSession(_asset, _session)) createSession(_asset, _session + 3600);
    }

    function exercise(
        bytes16 _asset,
        bytes16 _fundName,
        uint32 _session,
        uint32 _orderId,
        uint64 _amount,
        uint32 _returnRatio,
        uint64 _exPrice,
        uint32 _effectiveTime,     
        uint256 _nonce,
        bytes memory _signature
    ) external {
        require(_fundName == fundName, "106:invalid fund");
        SessionInfo storage session = assetSessions[_asset].info[_session];
        require(session.id == _session, "103:session not exist");
        require(_orderId < session.orders.length, "109:invalid order");
        require(session.orders[_orderId].user == _msgSender(), "110:invalid request");
        require(session.orders[_orderId].amount == _amount, "111:invalid amount");
        require(!session.orders[_orderId].exercised, "112:order exercised already");

        bytes memory message = abi.encode(_msgSender(), _asset, _fundName, _session, _orderId, _amount, _returnRatio, _exPrice, _effectiveTime, _nonce); 
        WocAuxer(wocAuxer).verifyMessage(
            ActionNonceType.Exercise,
            _msgSender(),
            _effectiveTime,
            _nonce,
            message, 
            _signature
        );

        session.orders[_orderId].exercised = true;
        uint64 payout = session.orders[_orderId].amount * _returnRatio / 1000;
        session.totalExPayout += payout;

        currentExPurchase += session.orders[_orderId].amount;
        currentExPayout += payout;
        totalUserBalance += payout;
        totalUnresolvedPurchase -= session.orders[_orderId].amount;
        emit Exercise (
            session.orders[_orderId].user,
            _asset,
            _session,
            _orderId,
            fundName,
            _returnRatio, 
            _exPrice,
            payout 
        );
    }

    function purchase(
        bytes16 _asset,
        bytes16 _fundName,
        uint32 _session,
        bool _long,
        uint64 _amount,
        uint64 _transferAmount,
        uint32[7] memory _pricePoints,
        uint32 _effectiveTime,     
        uint256 _nonce,
        bytes memory _signature
    ) external {
        require(_amount >= _transferAmount, "101:invalid amount");
        require(_amount >= wocConfig.minOrderSize && _amount <= wocConfig.maxOrderSize, "102:amount exceeds limits");
        require(_fundName == fundName, "106:invalid fund");
        SessionInfo storage session =  assetSessions[_asset].info[_session];
        require(session.id == _session, "103:session not exist");
        require(session.orders.length < maxOrdersPerSession, "108:exceed orders limit");
        require(session.totalExPayout < session.sessionFund, "104:insufficient liquidity");
        bytes memory message = abi.encode(_msgSender(), _asset, _fundName, _session, _long, _amount, _transferAmount, _pricePoints, _effectiveTime, _nonce); 
        WocAuxer(wocAuxer).verifyMessage(
            ActionNonceType.Order,
            _msgSender(),
            _effectiveTime,
            _nonce,
            message, 
            _signature
        );
        require(checkSessionFund(session, _long, _amount), "104:insufficient liquidity");
        
        processOrder(msg.sender, session, _asset, _long, _amount, _transferAmount, _pricePoints);
        if (_transferAmount > 0) {
            SafeERC20Upgradeable.safeTransferFrom(
                IERC20Upgradeable(fundERC20), 
                msg.sender, 
                address(this), 
                WocAuxer(wocAuxer).convertToExtFundAmount(_transferAmount, fundDecimals)
            );
        }

        if (_amount > _transferAmount) {
            totalUserBalance -= (_amount - _transferAmount);
        }
        totalUnresolvedPurchase += _amount;
    }   

    function processOrder(
        address _user, 
        SessionInfo storage session,
        bytes16 _asset,
        bool _long, 
        uint64 _amount, 
        uint64 _transferAmount,
        uint32[7] memory _pricePoints
    ) internal {
        uint64 orderAmount = _amount;
        uint64 warcReward = calculateWarcReward(session, _amount);
        // one purchase might generate multiple orders spreading among different max payout
        while (orderAmount > 0) { 
            (uint64 units, uint32 payoutIdx) = getCurrentPayoutAndAmount(session, _long);
            if (units >= orderAmount) {
                insertOrder(_user, _asset, session, _long, orderAmount, _amount-_transferAmount, warcReward, _pricePoints, payoutIdx);
                break;
            }
            else {
                orderAmount -= units;
                insertOrder(_user, _asset, session, _long, units, 0, 0, _pricePoints, payoutIdx);
            }
        }
    }

    function insertOrder(
        address _user, 
        bytes16 _asset,
        SessionInfo storage session,
        bool _long, 
        uint64 _amount, 
        uint64 _localAmount,
        uint64 _warcReward,
        uint32[7] memory _pricePoints,
        uint32 _maxPayoutIdx
    ) internal {
        OrderInfo memory order = OrderInfo(_user, _long, false, _amount, _maxPayoutIdx, _pricePoints);
        uint64 remainingUnits;
        if (order.long) {
            session.totalLong += order.amount;
            remainingUnits = session.totalUnits - session.totalLong;
        }
        else {
            session.totalShort += order.amount;
            remainingUnits = session.totalUnits - session.totalShort;
        }
        session.orders.push(order);
        uint32 orderId = uint32(session.orders.length - 1);
        emit Order(order.user, _asset, session.id, orderId, fundName, order.amount, _localAmount, _warcReward, order.pricePoints, order.long, payoutTable[order.maxPayoutIdx], remainingUnits);
    }

    function getCurrentPayoutAndAmount(SessionInfo storage session, bool _long) internal view returns (uint64 _units, uint32 _payoutId) {
        uint64 totalSales = _long? session.totalLong : session.totalShort;
        uint64 units = 0;
        for (uint32 i = session.maxPayoutIdx; i > 0; i--) {
            units += session.slotUnits[i];
            if (units > totalSales) {
                return (units - totalSales, i);
            }
        }
        require(false, "logic error");
    }

    function getAvailableUnitsAndPayout(bytes16 _asset, uint32 _session) external view returns (
        uint256 callUnits,
        uint256 callPayout,
        uint256 putUnits,
        uint256 putPayout
    ) {
        SessionInfo storage session = assetSessions[_asset].info[_session];
        if(session.id == 0) {
            return (0, 0, 0, 0);
        } 
        
        callUnits = session.totalUnits - session.totalLong;
        putUnits = session.totalUnits - session.totalShort;
        callPayout = putPayout = 0;
        uint64 units = 0;
        for (uint i = session.maxPayoutIdx; i > 0; i--) {
            units += session.slotUnits[i];
            if (callPayout == 0 && units > session.totalLong) {
                callPayout = payoutTable[i];
            }
            if (putPayout == 0 && units > session.totalShort) {
                putPayout = payoutTable[i];
            }
            if (callPayout > 0 && putPayout > 0) break;
        }
    }

    function createSession(bytes16 _asset, uint32 _session) internal returns (bool) {
        uint64 _sessionFund = WocFundPool(fundPool).allocateSessionFund(_asset, _session);
        if (_sessionFund == 0) return false;
        SessionInfo storage session = assetSessions[_asset].info[_session];
        session.id = _session;
        session.maxPayoutIdx = wocConfig.maxPayoutIdx;
        session.sessionFund =  _sessionFund;
        currentSessionFund += _sessionFund;

        _sessionFund = uint64(_sessionFund * wocConfig.dirFundRatio / 100 / 10 ** TokenPrecision);
        for (uint i = 0; i <= session.maxPayoutIdx; i++)
        {
            session.slotUnits[i] = uint32(
                            (_sessionFund * fundPortion[i] / 10000) 
                            / payoutTable[i] 
                            * (10 ** TokenPrecision));
            session.totalUnits += session.slotUnits[i];
        }
        
        assetSessions[_asset].sessionIds.push(_session);
        return true;
    }

    function checkSessionFund(SessionInfo storage session, bool _long, uint64 _amount) internal view returns (bool)  {
        if (_long) 
            if (_amount > session.totalUnits - session.totalLong) return false;
        else
            if (_amount > session.totalUnits - session.totalShort) return false;
        
        return true;
    }

    function getSessionOrders(bytes16 _asset, uint32 _session) public view returns (OrderInfo[] memory orders) {
        return assetSessions[_asset].info[_session].orders;
    }

    function getSessionStatus(bytes16 _asset, uint32 _session) external view returns (
        uint64 totalLong,
        uint64 totalShort,
        uint64 issuedWarcReward,
        uint32 orders,
        uint64[7] memory slotUnits,
        uint32 maxPayoutIdx,       
        uint64 totalUnits,
        uint64 exPayout,
        uint64 fund
    ) {
        SessionInfo storage session = assetSessions[_asset].info[_session];
        return (
            session.totalLong,
            session.totalShort,
            session.issuedWarcReward,
            uint32(session.orders.length),
            session.slotUnits,
            session.maxPayoutIdx,
            session.totalUnits,
            session.totalExPayout,
            session.sessionFund
        );
    }

    function getSessionInfo(bytes16 _asset) external view returns (
        uint32[] memory sessionIds
    ) {
        return assetSessions[_asset].sessionIds;
    }

    function getOpStats() external view returns (
        uint64 issuedWarcReward, 
        uint64 userBalance, 
        uint64 unResolvedPurchase,
        uint64 sessionFund,
        uint64 exPayout,
        uint64 exPurchase
    ) {
        //balanceOf(wocmain) = totalSessionFund + totalUserBalance + totalUnresolvedPurchase - currentExPayout + currentExPurchase
        return (totalWarcRewards, totalUserBalance, totalUnresolvedPurchase, currentSessionFund, currentExPayout, currentExPurchase);
    }
    
    function draw(uint32 _session, bytes16[] calldata _assets,  uint32[] calldata _prices) onlyOracle external {
        require(_assets.length == _prices.length, "invalid draw");
        uint len = _assets.length;
        SessionResult memory sessionResult;
        for (uint i = 0; i < len; i++) {
            assetDraw(sessionResult, _session, _assets[i], _prices[i]);
        }
        currentSessionFund -= sessionResult.totalFund;
        totalUserBalance += sessionResult.totalDrawPayout;
        currentExPayout -= sessionResult.totalExPayout;
        currentExPurchase -= (sessionResult.totalPurchase - sessionResult.totalDrawPurchase);
        totalUnresolvedPurchase -= sessionResult.totalDrawPurchase;
        
        uint64 totalPayout = sessionResult.totalDrawPayout + sessionResult.totalExPayout;
        if (sessionResult.totalFund + sessionResult.totalPurchase > totalPayout) {
            SafeERC20Upgradeable.safeTransfer(
                IERC20Upgradeable(fundERC20),
                fundPool,
                WocAuxer(wocAuxer).convertToExtFundAmount(
                        sessionResult.totalFund + sessionResult.totalPurchase - totalPayout, 
                        fundDecimals)
            ); 
        }
        WocFundPool(fundPool).sessionResult(_assets, _session, sessionResult.totalFund, sessionResult.totalPurchase, totalPayout, sessionResult.warcReward);
        
        for (uint i = 0; i < len; i++) {
            postSessionDraw(_session, _assets[i]);
        }
    }

    function postSessionDraw(uint32 _session, bytes16 _asset) internal {
        SessionContainer storage sessions = assetSessions[_asset];
        for (uint i = 0; i < sessions.sessionIds.length - 1; i++) {
            sessions.sessionIds[i] = sessions.sessionIds[i + 1];
        }
        sessions.sessionIds.pop();
        delete sessions.info[_session];

        uint32 nextSession = sessions.sessionIds.length > 0? sessions.sessionIds[0] + 3600 : 0;
        if (block.timestamp > nextSession) {
            uint32 _hours = uint32((block.timestamp - nextSession) / 3600) + 1;
            nextSession += _hours * 3600;
        }  
        if (createSession(_asset, nextSession)) {
            if (sessions.sessionIds.length == 1) createSession(_asset, nextSession + 3600);
        }
    }

    function assetDraw(SessionResult memory sessionResult, uint32 _session, bytes16 _asset,  uint32 _price) internal {
        SessionContainer storage sessions = assetSessions[_asset];
        require(sessions.info[_session].id > 0, "session not found");
        require(sessions.sessionIds[0] == _session, "session draw out of order");
        SessionInfo storage session = sessions.info[_session];
        uint totalOrders = session.orders.length;
        uint64 maturePayout = 0;
        uint64 exMaturePayout = 0;
        uint64 resolvedPurchase = 0;
        for (uint i = 0; i < totalOrders; i++) {
            uint64 payout = resolveOrder(_price, session.orders[i]);
            if (payout > 0) {
                if (session.orders[i].exercised) 
                    exMaturePayout += payout;
                else 
                    maturePayout += payout;
            }

            if(!session.orders[i].exercised)
                resolvedPurchase += session.orders[i].amount;  
        }
        sessionResult.totalDrawPurchase += resolvedPurchase;
        sessionResult.totalPurchase += (session.totalLong + session.totalShort);
        sessionResult.totalDrawPayout += maturePayout; 
        sessionResult.totalExPayout += session.totalExPayout;
        sessionResult.warcReward += session.issuedWarcReward;
        sessionResult.totalFund += session.sessionFund;
        
        emit SessionSummary(
            _asset,
            _session,
            fundName, 
            _price,
            session.totalLong, 
            session.totalShort, 
            uint32(totalOrders), 
            session.issuedWarcReward,
            session.totalExPayout,
            exMaturePayout,
            maturePayout
        );
    }

    function resolveOrder(uint32 _price, OrderInfo storage _order) internal view returns (uint64) {
        uint32 i = 0;
        for (; i <= _order.maxPayoutIdx; i++) {
            if (_order.long) {
                // 100, 120, 130, 140, 150, 160, 170
                if (_price < _order.pricePoints[i]) {
                    break;
                }
            }
            else {
                // 90, 80, 70, 60, 50, 40, 30
                if (_price > _order.pricePoints[i]) {
                    break;
                }
            }
        }
        
        return i > 0? _order.amount * payoutTable[i-1] : 0;
    }

    function calculateWarcReward(SessionInfo storage session, uint64 _amount) internal returns (uint64 totalReward) {
        uint64 sessionRemainingReward;
        if (rewardSetting.sessionRewardMax > session.issuedWarcReward) {
            sessionRemainingReward = rewardSetting.sessionRewardMax - session.issuedWarcReward; 
        }
        else {     
            return 0;
        }
        totalReward = 0; 
        uint64 previousSale = session.totalLong + session.totalShort;
        uint64 amount = _amount;
        
        while (amount > 0 && sessionRemainingReward > 0) {
            (uint32 ratio, uint64 saleLimit) = getRewardRatio(previousSale);
            uint64 rewardBase = amount;
            if (saleLimit > 0) {
                rewardBase = saleLimit - previousSale;
                if (rewardBase > amount) {
                    rewardBase = amount;
                }
            }
            
            uint64 reward = rewardBase * ratio / 100;
            if (sessionRemainingReward < reward) {
                reward = sessionRemainingReward;
            } 
            sessionRemainingReward -= reward;
            totalReward += reward;
            amount -= rewardBase;
            previousSale = saleLimit;
        }
        session.issuedWarcReward += totalReward;
        totalWarcRewards += totalReward;
    }

    function getRewardRatio(uint64 _currentSale) internal view returns (uint32, uint64) {
        uint i = rewardSetting.salesRanks.length - 1;
        for (; i > 0 ; i--) {
            if (_currentSale >= rewardSetting.salesRanks[i]) {
                break;    
            }
        }
        uint64 salesRank = (i == rewardSetting.salesRanks.length - 1) ? 0 : rewardSetting.salesRanks[i+1];
        return (rewardSetting.rewardRatios[i], salesRank);
    }

    function userWithdraw(
        uint32 _amount, 
        bytes16 _fundName,
        uint32 _effectiveTime,     
        uint256 _nonce, 
        bytes memory _signature
    ) external {
        require(totalUserBalance >= _amount, "107:invalid withdraw amount");
        require(_fundName == fundName, "106:invalid fund");
        address sender = _msgSender();
        bytes memory message = abi.encode(sender, _amount, _fundName, _effectiveTime, _nonce); 
        WocAuxer(wocAuxer).verifyMessage(
            ActionNonceType.WithdrawWinning,
            sender,
            _effectiveTime,
            _nonce,
            message, 
            _signature
        );
        totalUserBalance -= _amount;
        SafeERC20Upgradeable.safeTransfer(  
            IERC20Upgradeable(fundERC20),
            sender,
            WocAuxer(wocAuxer).convertToExtFundAmount(_amount, fundDecimals)
        );

        emit UserBalanceWithdraw(
            sender,
            fundName,
            _amount
        );
    }  

    modifier onlyOracle {
        require(_msgSender() == oracle, "invalid caller");
        _;
    }  
}
