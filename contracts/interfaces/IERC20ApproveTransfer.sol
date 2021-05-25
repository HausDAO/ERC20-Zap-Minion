interface IERC20ApproveTransfer { // interface for erc20 approve/transfer
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}