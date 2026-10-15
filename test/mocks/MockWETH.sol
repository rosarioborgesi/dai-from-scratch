// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

//  WETH9 contract mock
contract MockWETH is ERC20 {
    error EtherTransferFailed();

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external  {
        address account = _msgSender();

        // Update balances before making the external call.
        _burn(account, amount);

        (bool success, ) = payable(account).call{value: amount}("");
        if (!success) {
            revert EtherTransferFailed();
        }
        emit Withdrawal(account, amount);
    }
}
