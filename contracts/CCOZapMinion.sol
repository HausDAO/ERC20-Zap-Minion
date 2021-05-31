import "./interfaces/IERC20ApproveTransfer.sol";
import "./interfaces/IMOLOCH.sol";
import "./helpers/Context.sol";
import "./helpers/Ownable.sol";
import "./helpers/ReentrancyGuard.sol";
import "./helpers/SafeMath.sol";


contract CCOZapMinion is ReentrancyGuard {
    using SafeMath for uint256;
    
    IMOLOCH public moloch;
    
    address public contribToken; // token accepted for CCO
    address public projToken; // token distributed by project
    uint256 public zapRate; // rate to convert ether into zap proposal share request (e.g., `10` = 10 shares per 1 ETH sent)
    uint256 public startTime; // beginning of when ppl can call the zapIt function 
    uint256 public endTime; // end of when ppl can call the zapIt function 
    uint256 public unlockTime; // when ppl can withdraw project token 
    uint256 public maxContrib; // max individual contribution in a CCO
    uint256 public ccoMax; // max total to be raised
    uint256 public ccoFunds; // tracking total contributed
    uint256 public updateCount; // tracking updates 
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern

    mapping(uint256 => Zap) public zaps; // proposalId => Zap
    mapping(uint256 => Update) public updates; // update # => update 
    mapping(address => uint256) public contributions; // proposer => total contributions 
    
    struct Zap {
        address proposer;
        address token;
        bool processed;
        uint256 zapAmount;
       
    }
    
    struct Update {
        bool implemented;
        uint256 startBlock;
        uint256 newRate; 
        uint256 newStart;
        uint256 newEnd;
        address manager;
        address token;
        string newDetails;
    }

    event ProposeZap(uint256 amount, address indexed proposer, uint256 proposalId);
    event WithdrawZapProposal(address indexed proposer, uint256 proposalId);
    event UpdateZapMol(address indexed manager, address indexed wrapper, uint256 zapRate, string zapDetails);
    event UpdateImplemented(bool implemented);

    modifier memberOnly() {
        require(isMember(msg.sender), "AP::not member");
        _;
    }
    
    /**
     * @dev init function in place of constructor due to EIP-1167 proxy pattern
     * @param _moloch The address of the CCO moloch
     * @param _contribToken The token to be used for the CCO, must be whitelisted in the moloch.
     * @param _zapRate The ratio of contribution token to loot shares, must be greater than 1*10^18 per loot share
     * @param _startTime The unix timestamp for when ppl can begin submitting CCO proposals 
     * @param _endTime The unix timestamp for when the CCO closes its contribution period 
     * @param _maxContrib The max number of tokens a user address can contribute to the CCO
     * @param _ccoMax The max number of tokens the CCO will accept before it closes. 
     **/

    function init(
        address _moloch, 
        address _contribToken, 
        address _projToken,
        uint256 _zapRate, 
        uint256 _startTime, 
        uint256 _endTime,
        uint256 _unlockTime,
        uint256 _maxContrib,
        uint256 _ccoMax
    ) external {
        
        require(!initialized, "CCOZap::initialized");
        require(_startTime > block.timestamp, "CCOZap:: Bad startTime");
        require(_endTime > _startTime, "CCOZap:: Bad endTime");
        require(_maxContrib > zapRate, "CCOZap:: Max too small");
        
        contribToken = _contribToken;
        projToken = _projToken;
        moloch = IMOLOCH(_moloch);
        zapRate = _zapRate;
        startTime = _startTime;
        endTime = _endTime;
        unlockTime = _unlockTime;
        maxContrib = _maxContrib;
        ccoMax = _ccoMax;
        ccoFunds = 0;
        initialized = true; 
        
        IERC20ApproveTransfer(_contribToken).approve(_moloch, type(uint256).max); // Go ahead and approve moloch to spend token
    }
    
    /**
     * Contribute function for ppl to give to a CCO 
     * Caller submits a membership prooposal for loot to the CCO DAO
     * @param amount The amount of token user wants to give
     **/
    
    function contribute(uint256 amount) external nonReentrant returns (uint256) { 

        require(amount % 10**18  == 0, "CCOZap:: less than whole token");
        require(amount % zapRate  == 0, "CCOZap:: no fractional shares");
        require(amount <= maxContrib && amount + contributions[msg.sender] <= maxContrib, "CCOZap:: give less");
        require(ccoFunds + amount <= ccoMax, "CCOZap:: CCO full");
        require(block.timestamp >= startTime, "CCOZap:: !started");
        require(block.timestamp <= endTime, "CCOZap:: ended");
        
        IERC20ApproveTransfer(contribToken).transferFrom(msg.sender, address(this), amount); // move funds from user to minion 
        
        uint256 proposalId = moloch.submitProposal(
            msg.sender,
            0,
            amount.div(zapRate).div(10**18), // loot shares
            amount,
            contribToken,
            0,
            contribToken,
            "CCO Contribution"
        );
        
        contributions[msg.sender] += amount;
        ccoFunds += amount;
        
        zaps[proposalId] = Zap(msg.sender, contribToken, false, amount);

        emit ProposeZap(amount, msg.sender, proposalId);
        return proposalId;
    }
    
    /**
     * For cancelling CCO contributions 
     * @dev Can only be called by the original proposer prior to thier proposal being sponsored
     * @param proposalId The proposalId of the original membership proposal 
     **/
    
    function cancelZapProposal(uint256 proposalId) external nonReentrant { // zap proposer can cancel zap & withdraw proposal funds 
        
        Zap storage zap = zaps[proposalId];
        require(msg.sender == zap.proposer, "CCOZap::!proposer");
        require(!zap.processed, "CCOZap::already processed");
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        require(!flags[0], "CCOZap::already sponsored");
        
        uint256 zapAmount = zap.zapAmount;
        moloch.cancelProposal(proposalId); // cancel zap proposal in parent moloch
        moloch.withdrawBalance(contribToken, zapAmount); // withdraw zap funds from moloch
        zap.processed = true;

        IERC20ApproveTransfer(contribToken).transfer(msg.sender, zapAmount); // redirect funds to zap proposer
        
        emit WithdrawZapProposal(msg.sender, proposalId);
    }
    
    /**
     * Easy way for contributors with a failed proposal to withdraw funds back to their wallet
     * @dev Can only be called by the original proposer after the proposal failed and was processed
     * @param proposalId The proposalId of the original membership proposal 
     **/
    
    function drawZapProposal(uint256 proposalId) external nonReentrant { 
        
        Zap storage zap = zaps[proposalId];
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        
        require(msg.sender == zap.proposer, "CCOZap::!proposer");
        require(!zap.processed, "CCOZap::already processed");
        require(flags[1] && !flags[2], "CCOZap::proposal passed");
        
        uint256 zapAmount = zap.zapAmount;
        moloch.withdrawBalance(contribToken, zapAmount); // withdraw zap funds from parent moloch
        zap.processed = true;
                
        IERC20ApproveTransfer(contribToken).transfer(msg.sender, zapAmount); // redirect funds to zap proposer
        
        emit WithdrawZapProposal(msg.sender, proposalId);
    }
    
    /**
     * Easy way for members to withdraw the locked up project tokens into the CCO DAO 
     * @dev Can only be called by a member 
     **/
     
    function withdrawProjTokens() external memberOnly returns (uint256){
        
        uint256 amount = IERC20ApproveTransfer(projToken).balanceOf(address(this));
        
        require(block.timestamp >= unlockTime, "CCOZap:: Tokens !unlocked");
        require(amount > 0, "CCOZap:: No Tokens");
        
        IERC20ApproveTransfer(address(this)).transfer(address(moloch), amount);
        
        return amount;
    }
    
    /**
     * Easy way for the minion manager to update settings
     * @dev Uses timestamp to make sure the update can't be processed in same block its submitted
     * @dev Also prevents new updates until prior updates are implemented 
     * @param _manager The new manager, should be old managers address if sticking with same manager
     * @param _newToken The new CCO token to be used for contribute()
     * @param _zapRate The new ratio of tokens to loot shares
     * @param _zapDetails The new details
     **/
    
    function updateZapMol( // manager adjusts zap proposal settings
        address _manager, 
        address _newToken, 
        uint256 _zapRate, 
        uint256 _startTime,
        uint256 _endTime,
        string calldata _zapDetails
    ) external nonReentrant memberOnly returns (uint256){ 
        
        require(!updates[updateCount].implemented || updateCount == 0, "CCOZap::prior update !implemented");
        
        uint256 updateId = updateCount;
        updates[updateId] = Update(false, block.timestamp, _zapRate, _startTime, _endTime, _manager, _newToken, _zapDetails);
        updateCount++;
        
        emit UpdateZapMol(_manager, _newToken, _zapRate, _zapDetails);
        return updateId;
    }
    
    /**
     * Way to implement a pending update
     * @dev Must be called at least one block later to allay security concerns
     * @param updateId The update to be implemented
     **/
    
    function implmentUpdate(uint256 updateId) external nonReentrant memberOnly returns (bool) {
        Update memory update = updates[updateId];
        require(!update.implemented, "CCOZap:: already implemented");
        require(updates[updateId-1].implemented, "CCOZap:: must implement prior update");
        require(block.timestamp > update.startBlock, "CCOZap:: must wait to implement");
    
        zapRate = update.newRate;
        contribToken = update.token;
        
        IERC20ApproveTransfer(update.token).approve(address(moloch), type(uint256).max);
        
     emit UpdateImplemented(true);
     return true;
  
    } 
    
    function isMember(address user) internal view returns (bool) {
        (, uint256 shares,,,,) = moloch.members(user);
        return shares > 0;
    }
    
    receive() external payable {
        revert("Don't send xDAI or ETH here");
    }
}

