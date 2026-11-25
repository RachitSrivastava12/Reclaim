// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface ISablierLockup {
    event CancelLockupStream(
        uint256 streamId,
        address indexed sender,
        address indexed recipient,
        address indexed token,
        uint128 senderAmount,
        uint128 recipientAmount
    );

    function withdraw(uint256 streamId, address to, uint128 amount) external payable;
    function withdrawableAmountOf(uint256 streamId) external view returns (uint128);
    function getRecipient(uint256 streamId) external view returns (address);
    function getUnderlyingToken(uint256 streamId) external view returns (address);
    function wasCanceled(uint256 streamId) external view returns (bool);
    function isDepleted(uint256 streamId) external view returns (bool);
    function isTransferable(uint256 streamId) external view returns (bool);
    function calculateMinFeeWei(uint256 streamId) external view returns (uint256);
}
