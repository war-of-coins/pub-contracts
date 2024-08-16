// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

enum ActionNonceType {
    Order,                  // make option order
    WithdrawWinning,        // withdraw winning
    LpWithdraw,             // LP withdraw cash dividend
    LpWithdrawWarc,         // LP withdraw warc reward
    MlmWithdraw,            // Member withdraw mlm rev sharing
    Exercise                // American style exercise
}

uint8 constant TokenPrecision = 3;

contract WocAuxer is Initializable, OwnableUpgradeable {
    mapping(address => mapping(uint256 => uint256)) userNonces;
    address oracle;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _oracle) public initializer {
        __Ownable_init();
        oracle = _oracle;
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
    }

    function getOracle() external view onlyOwner returns (address) {
        return oracle;
    }

    function getCurrentNonce(address _addr, uint256 _type) public view returns (uint256) {
        return userNonces[_addr][_type];
    }

    function verifyMessage(
        ActionNonceType _type,
        address _addr,
        uint256 _effectiveTime,     // order effective time in seconds
        uint256 _nonce,
        bytes memory _message,
        bytes memory _signature
    ) external {
        require(
            verifySingaure(_message, _signature), 
            "invalid signature"
        );
        require(block.timestamp < _effectiveTime, "request expired");
        require(_nonce > userNonces[_addr][uint256(_type)], "request already processed");
        userNonces[_addr][uint256(_type)] = _nonce;
    }

    function verifySingaure(
        bytes memory _message,
        bytes memory _signature
    ) internal view returns (bool) {
        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(_message.length), _message));
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);
        address signer = ecrecover(ethSignedMessageHash, v, r, s);
        return (signer == oracle);
    }

    function splitSignature(bytes memory sig)
        internal
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        require(sig.length == 65, "invalid signature length");

        assembly {
            /*
            First 32 bytes stores the length of the signature

            add(sig, 32) = pointer of sig + 32
            effectively, skips first 32 bytes of signature

            mload(p) loads next 32 bytes starting at the memory address p into memory
            */

            // first 32 bytes, after the length prefix
            r := mload(add(sig, 32))
            // second 32 bytes
            s := mload(add(sig, 64))
            // final byte (first byte of the next 32 bytes)
            v := byte(0, mload(add(sig, 96)))
        }

        // implicitly return (r, s, v)
    }

    function convertToExtFundAmount(uint64 _amount, uint8 _fundDecimals) external pure returns (uint256) {
        return _amount * 10 ** (_fundDecimals - TokenPrecision);
    }  
}
