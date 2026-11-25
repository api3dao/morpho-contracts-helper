// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IApi3ServerV1} from "./external/api3/interfaces/IApi3ServerV1.sol";
import {IMorpho, MarketParams} from "./external/morpho/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Updates API3 feeds and liquidates Morpho Blue positions in one transaction.
/// @dev Anyone may call `updateAndLiquidate`. A caller can only spend what it brings: the builder
///      tip is paid from `msg.value` (excess refunded), and only the tokens this liquidation adds to
///      the helper are swept to the caller. ETH and tokens already held by the helper are untouched
///      and can be withdrawn only by the owner.
contract LiquidationHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IApi3ServerV1 public immutable api3ServerV1;
    IMorpho public immutable morpho;
    address public immutable owner;

    struct LiquidationParams {
        MarketParams marketParams;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
        bytes   data;
    }

    constructor(address _api3ServerV1, address _morpho) {
        api3ServerV1 = IApi3ServerV1(_api3ServerV1);
        morpho     = IMorpho(_morpho);
        owner      = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function _executeMulticall(bytes[] calldata data) internal {
        uint256 callCount = data.length;
        for (uint256 ind = 0; ind < callCount; ) {
            bool success;
            bytes memory returndata;
            
            (success, returndata) = address(api3ServerV1).call(data[ind]);
            
            if (!success) {
                if (returndata.length > 0) {
                    assembly {
                        let returndata_size := mload(returndata)
                        revert(add(32, returndata), returndata_size)
                    }
                } else {
                    revert("Multicall: No revert string");
                }
            }
            unchecked { ind++; }
        }
    }

    function multicallAndTip(bytes[] calldata data) external payable {
        require(msg.value > 0, "No tip");
        _executeMulticall(data);
        _tipBuilder(msg.value);
    }

    function _tipBuilder(uint256 amount) private {
        (bool tipped, ) = block.coinbase.call{value: amount}("");
        require(tipped, "Coinbase tip failed");
    }

    function updateAndLiquidate(
        bytes[] calldata data,
        LiquidationParams calldata liq,
        uint256 maxUSDCToUse,
        uint256 tipAmount
    ) external payable nonReentrant {
        uint256 finalTip = tipAmount > 0 ? tipAmount : msg.value;
        require(finalTip <= msg.value, "Tip exceeds msg.value");

        IERC20 loanToken = IERC20(liq.marketParams.loanToken);
        IERC20 collateralToken = IERC20(liq.marketParams.collateralToken);

        uint256 loanBefore = loanToken.balanceOf(address(this));
        uint256 collateralBefore = collateralToken.balanceOf(address(this));

        loanToken.safeTransferFrom(msg.sender, address(this), maxUSDCToUse);

        _executeMulticall(data);
        loanToken.forceApprove(address(morpho), type(uint256).max);
        morpho.liquidate(liq.marketParams, liq.borrower, liq.seizedAssets, liq.repaidShares, liq.data);
        loanToken.forceApprove(address(morpho), 0);

        // Repayment must be covered by the caller's tokens, never by the helper's own balance.
        uint256 loanAfter = loanToken.balanceOf(address(this));
        require(loanAfter >= loanBefore, "Repay exceeds caller funds");
        if (loanAfter > loanBefore) {
            loanToken.safeTransfer(msg.sender, loanAfter - loanBefore);
        }

        // Measured after the loan sweep so a market with loanToken == collateralToken is not double-counted.
        uint256 collateralAfter = collateralToken.balanceOf(address(this));
        if (collateralAfter > collateralBefore) {
            collateralToken.safeTransfer(msg.sender, collateralAfter - collateralBefore);
        }

        if (finalTip > 0) {
            _tipBuilder(finalTip);
        }
        uint256 refund = msg.value - finalTip;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "Refund failed");
        }
    }

    function withdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        (bool ok,) = owner.call{value: amount}("");
        require(ok, "ETH withdraw failed");
    }

    receive() external payable {}
}
