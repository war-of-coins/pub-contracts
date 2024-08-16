// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { ActionNonceType } from "./wocauxer.sol";

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

/**
 * @title WocVault
 * @dev This contract holds dividend assets including liquidity fund and warc rewards.
 * liquidity fund contains LP cash dividend, LP fund withdraw and MLM rev sharing 
 */
contract WocVault is Initializable, OwnableUpgradeable {
    struct FundInfo {
        address addr;
        uint8 fundDecimals;
        uint128 totalLpWithdraw;
        uint128 totalMlmWithdraw;
    }

    event VaultWithdraw(
        address indexed user,
        bytes16 indexed fund,
        uint32 withdrawType,
        uint32 amount
    );

    mapping(bytes16 => FundInfo) funds;
    address public wocAuxer;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _wocAuxer) public initializer {
        __Ownable_init();
        wocAuxer = _wocAuxer;
    }

    function addFundInfo(bytes16 _fundName, address _addr) external onlyOwner {
        require(funds[_fundName].addr == address(0), "fund already exist");
        funds[_fundName].addr = _addr;
        funds[_fundName].fundDecimals = ERC20Upgradeable(_addr).decimals();
    }

    function vaultWithdraw(
        bytes16 _fundName,
        uint32 _amount,
        uint32 _type,
        uint32 _effectiveTime,
        uint256 _nonce,
        bytes memory _signature
    ) external {
        require(_type == uint32(ActionNonceType.MlmWithdraw) ||
                _type == uint32(ActionNonceType.LpWithdraw),
                "invalid type");
        
        bytes memory message = abi.encode(_msgSender(), _fundName, _amount, _type, _effectiveTime, _nonce); 
        WocAuxer(wocAuxer).verifyMessage(
            ActionNonceType(_type),
            _msgSender(),
            _effectiveTime,
            _nonce,
            message, 
            _signature
        );

        require(funds[_fundName].addr != address(0), "fund not exist");
        FundInfo storage fundInfo = funds[_fundName];
        SafeERC20Upgradeable.safeTransfer(  
            IERC20Upgradeable(fundInfo.addr),
            _msgSender(),
            WocAuxer(wocAuxer).convertToExtFundAmount(_amount, fundInfo.fundDecimals)
        );

        if (_type == uint32(ActionNonceType.LpWithdraw)) 
            fundInfo.totalLpWithdraw += _amount;
        else
            fundInfo.totalMlmWithdraw += _amount;
        
        emit VaultWithdraw(
            _msgSender(),
            _fundName,
            _type,
            _amount
        );
    }

    function vaultFundInfo(bytes16 _fundName) external view returns (
        uint128 lpWithdraw,
        uint128 mlmWithdraw,
        address addr
    ) {
        return(
            funds[_fundName].totalLpWithdraw, 
            funds[_fundName].totalMlmWithdraw, 
            funds[_fundName].addr
        );
    }
}
