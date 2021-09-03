// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.8.0;

interface IBooMdexPool {

    function poolLength() external view returns (uint256);

    function rewardToken() external view returns (address);

    function poolInfo(uint256 _pid) external view returns(address, uint256, uint256, uint256, uint256);

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256, uint256);

    function deposit(uint256 _pid, uint256 _amount) external;

    function pendingRewards(uint256 _pid, address _user) external view returns (uint256);

    function withdraw(uint256 _pid, uint256 _amount) external;

    function claim(uint256 _pid) external returns (uint256 value);

    function emergencyWithdraw(uint256 _pid) external;

}
