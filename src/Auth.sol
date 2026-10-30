// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Manages administrative permissions and restricts access to authorized addresses.
abstract contract Auth {
    // Stores authorization status for each address. (0 not authorized, 1 authorized)
    mapping(address user => uint256 authorized) private s_wards;

    event Rely(address indexed user);
    event Deny(address indexed user);

    // Only authorized addresses (1) can execute this function
    modifier auth() {
        if (s_wards[msg.sender] != 1) {
            _revertNotAuthorized();
        }
        _;
    }

    constructor() {
        s_wards[msg.sender] = 1;
    }

    // Grants administrative permissions to the user
    function rely(address user) external auth {
        _beforeRely();
        s_wards[user] = 1;
        emit Rely(user);
    }

    // Revokes administrative permissions to the user
    function deny(address user) external auth {
        _beforeDeny();
        s_wards[user] = 0;
        emit Deny(user);
    }

    // Revert with a custom error in the auth modifier
    function _revertNotAuthorized() internal pure virtual;

    // Checks to be made before granting authorization.
    function _beforeRely() internal view virtual {}

    // Checks to be made before revoking authorization.
    function _beforeDeny() internal view virtual {}

    function wards(address user) external view returns (uint256) {
        return s_wards[user];
    }
}
