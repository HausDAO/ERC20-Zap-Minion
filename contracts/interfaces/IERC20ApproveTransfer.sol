interface IERC20ApproveTransfer { // interface for erc20 approve/transfer
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address holder) external returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}