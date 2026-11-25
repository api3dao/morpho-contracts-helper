// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {AggregatorV3Interface} from "./external/morpho/interfaces/AggregatorV3Interface.sol";
import {IMorpho, MarketParams, Market,  Id, Position} from "./external/morpho/interfaces/IMorpho.sol";
import {IMorphoChainlinkOracleV2} from "./external/morpho/interfaces/IMorphoChainlinkOracleV2.sol";
import {IERC4626} from "./external/morpho/interfaces/IERC4626.sol";
import {IOracle} from "./external/morpho/interfaces/IOracle.sol";

contract MorphoMarketDataFetcher {

    address public immutable morphoAddress;

    constructor(address _morphoAddress) {
        morphoAddress = _morphoAddress;
    }

    struct TokenInfo {
        address tokenAddress;
        string name;
        string symbol;
        uint8 decimals;
        uint256 userAllowance;
    }

    struct MockOracleInfo {
        address oracleAddress;
        uint256 price;
        string symbol;
        uint8 decimals;
    }

    struct OracleInfo {
        address oracleAddress;
        AggregatorV3Interface baseFeed1;
        AggregatorV3Interface baseFeed2;
        IERC4626 baseVault;
        uint256 baseVaultConversionSample;
        AggregatorV3Interface quoteFeed1;
        AggregatorV3Interface quoteFeed2;
        IERC4626 quoteVault;
        uint256 quoteVaultConversionSample;
        uint256 scaleFactor;
        uint256 currentPrice;
        MockOracleInfo baseFeed;
        MockOracleInfo quoteFeed;
    }

    struct MarketData {
        TokenInfo loanToken;
        TokenInfo collateralToken;
        OracleInfo oracle;
        MarketParams marketParams;
        uint256 deadAddressSupply;
    }

    /// @notice Returns token, oracle and feed metadata for a Morpho Blue market.
    /// @dev Never reverts on a misbehaving or missing token/oracle/feed: every external read is a
    ///      low-level staticcall, and fields that cannot be read are left zero/empty. This covers
    ///      addresses without code (e.g. idle markets with collateralToken == address(0)),
    ///      tokens returning bytes32 from name()/symbol(), and malformed return data.
    function getMarketDetails(
        bytes32 marketId,
        address user
    ) external view returns (MarketData memory data) {

        MarketParams memory params = IMorpho(morphoAddress).idToMarketParams(Id.wrap(marketId));
        
        data.marketParams = params;

        data.loanToken = _tokenInfo(params.loanToken, user);
        data.collateralToken = _tokenInfo(params.collateralToken, address(0));

        address oracle = params.oracle;
        if (oracle.code.length > 0) {
            data.oracle.oracleAddress = oracle;
            data.oracle.baseFeed1 = AggregatorV3Interface(_tryAddress(oracle, IMorphoChainlinkOracleV2.BASE_FEED_1.selector));
            data.oracle.baseFeed2 = AggregatorV3Interface(_tryAddress(oracle, IMorphoChainlinkOracleV2.BASE_FEED_2.selector));
            data.oracle.baseVault = IERC4626(_tryAddress(oracle, IMorphoChainlinkOracleV2.BASE_VAULT.selector));
            data.oracle.baseVaultConversionSample = _tryUint(oracle, IMorphoChainlinkOracleV2.BASE_VAULT_CONVERSION_SAMPLE.selector);
            data.oracle.quoteFeed1 = AggregatorV3Interface(_tryAddress(oracle, IMorphoChainlinkOracleV2.QUOTE_FEED_1.selector));
            data.oracle.quoteFeed2 = AggregatorV3Interface(_tryAddress(oracle, IMorphoChainlinkOracleV2.QUOTE_FEED_2.selector));
            data.oracle.quoteVault = IERC4626(_tryAddress(oracle, IMorphoChainlinkOracleV2.QUOTE_VAULT.selector));
            data.oracle.quoteVaultConversionSample = _tryUint(oracle, IMorphoChainlinkOracleV2.QUOTE_VAULT_CONVERSION_SAMPLE.selector);
            data.oracle.scaleFactor = _tryUint(oracle, IMorphoChainlinkOracleV2.SCALE_FACTOR.selector);
            data.oracle.currentPrice = _tryUint(oracle, IOracle.price.selector);
        }

        data.oracle.baseFeed = _feedInfo(address(data.oracle.baseFeed1));
        data.oracle.quoteFeed = _feedInfo(address(data.oracle.quoteFeed1));

        if (morphoAddress != address(0) && marketId != bytes32(0)) {
            address deadAddress = 0x000000000000000000000000000000000000dEaD;

            Position memory deadPosition = IMorpho(morphoAddress).position(Id.wrap(marketId), deadAddress);
            data.deadAddressSupply = deadPosition.supplyShares;
        }
    }

    function _tokenInfo(address token, address user) private view returns (TokenInfo memory info) {
        info.tokenAddress = token;
        if (token.code.length == 0) return info;

        info.name = _tryString(token, IERC20Metadata.name.selector);
        info.symbol = _tryString(token, IERC20Metadata.symbol.selector);
        info.decimals = _tryUint8(token, abi.encodeCall(IERC20Metadata.decimals, ()));

        if (user != address(0) && morphoAddress != address(0)) {
            (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("allowance(address,address)", user, morphoAddress));
            if (ok && ret.length >= 32) info.userAllowance = abi.decode(ret, (uint256));
        }
    }

    function _feedInfo(address feed) private view returns (MockOracleInfo memory info) {
        if (feed == address(0)) return info;
        info.oracleAddress = feed;
        if (feed.code.length == 0) return info;

        (bool ok, bytes memory ret) = feed.staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (ok && ret.length >= 160) {
            int256 answer;
            assembly {
                answer := mload(add(ret, 64)) // second word: answer
            }
            info.price = answer > 0 ? uint256(answer) : 0;
        }
        info.decimals = _tryUint8(feed, abi.encodeCall(AggregatorV3Interface.decimals, ()));
        info.symbol = _tryString(feed, AggregatorV3Interface.description.selector);
    }

    function _tryUint(address target, bytes4 selector) private view returns (uint256 value) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        if (ok && ret.length >= 32) value = abi.decode(ret, (uint256));
    }

    function _tryAddress(address target, bytes4 selector) private view returns (address) {
        uint256 value = _tryUint(target, selector);
        return value <= type(uint160).max ? address(uint160(value)) : address(0);
    }

    function _tryUint8(address target, bytes memory callData) private view returns (uint8) {
        (bool ok, bytes memory ret) = target.staticcall(callData);
        if (!ok || ret.length < 32) return 0;
        uint256 value = abi.decode(ret, (uint256));
        return value <= type(uint8).max ? uint8(value) : 0;
    }

    /// @dev Decodes an ABI-encoded string, or a bytes32 (e.g. MKR-style tokens). Returns "" otherwise.
    function _tryString(address target, bytes4 selector) private view returns (string memory) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSelector(selector));
        if (!ok) return "";

        if (ret.length >= 64) {
            uint256 offset;
            uint256 len;
            assembly {
                offset := mload(add(ret, 32))
            }
            if (offset == 32) {
                assembly {
                    len := mload(add(ret, 64))
                }
                if (len <= ret.length - 64) return abi.decode(ret, (string));
            }
            return "";
        }

        if (ret.length == 32) {
            bytes32 raw = abi.decode(ret, (bytes32));
            uint256 n;
            while (n < 32 && raw[n] != 0) n++;
            bytes memory out = new bytes(n);
            for (uint256 i; i < n; i++) out[i] = raw[i];
            return string(out);
        }

        return "";
    }
}
