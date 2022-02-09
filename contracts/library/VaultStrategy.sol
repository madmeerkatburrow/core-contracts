// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "../interfaces/IMasterChef.sol";

contract VaultStrategy {
    using SafeMath for uint256;
    IMasterChef public constant MMF_MASTER_CHEF = IMasterChef(0x6bE34986Fdd1A91e4634eb6b9F8017439b7b5EDc);
    uint256 public constant pid = 0;

    function balance() public view returns (uint256 amount) {
        (amount, ) = MMF_MASTER_CHEF.userInfo(pid, address(this));
    }
    
    function strategyBalanceOf(uint256 totalShares, uint256 userShares) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return balance().mul(userShares).div(totalShares);
    }
}