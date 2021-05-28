import "./interfaces/IERC20ApproveTransfer.sol";
import "./interfaces/IMOLOCH.sol";
import "./helpers/Context.sol";
import "./helpers/Ownable.sol";
import "./helpers/ReentrancyGuard.sol";
import "./helpers/SafeMath.sol";


contract CCOZapMinion is ReentrancyGuard {
    using SafeMath for uint256;
    
    IMOLOCH public moloch;
    
    address public manager; // account that manages moloch zap proposal settings (e.g., moloch via a minion)
    address public token; // token accepted for CCO
    uint256 public zapRate; // rate to convert ether into zap proposal share request (e.g., `10` = 10 shares per 1 ETH sent)
    uint256 public startTime; // beginning of when ppl can call the zapIt function 
    uint256 public endTime; // end of when ppl can call the zapIt function 
    uint256 public maxContrib; // max individual contribution in a CCO
    uint256 public ccoMax; // max total to be raised
    uint256 public ccoFunds; // tracking total contributed
    uint256 public updateCount; // tracking updates 
    string public ZAP_DETAILS; // general zap proposal details to attach
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern

    mapping(uint256 => Zap) public zaps; // proposalId => Zap
    mapping(uint256 => Update) public updates; // update # => update 
    mapping(address => uint256) public contribution; // proposer => total contributions 
    
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
        address manager;
        address token;
        string newDetails;
    }

    event ProposeZap(uint256 amount, address indexed proposer, uint256 proposalId);
    event WithdrawZapProposal(address indexed proposer, uint256 proposalId);
    event UpdateZapMol(address indexed manager, address indexed wrapper, uint256 zapRate, string ZAP_DETAILS);
    event UpdateImplemented(bool implemented);

    modifier memberOnly() {
        require(isMember(msg.sender), "AP::not member");
        _;
    }
    
    /**
     * @dev init function in place of constructor due to EIP-1167 proxy pattern
     * @param _manager The address of the minion manager for the purpose of updating the minion params (must be moloch member)
     * @param _moloch The address of the CCO moloch
     * @param _token The token to be used for the CCO, must be whitelisted in the moloch.
     * @param _zapRate The ratio of contribution token to loot shares, must be greater than 1*10^18 per loot share
     * @param _startTime The unix timestamp for when ppl can begin submitting CCO proposals 
     * @param _endTime The unix timestamp for when the CCO closes its contribution period 
     * @param _maxContrib The max number of tokens a user address can contribute to the CCO
     * @param _ccoMax The max number of tokens the CCO will accept before it closes. 
     **/

    function init(
        address _manager, 
        address _moloch, 
        address _token, 
        uint256 _zapRate, 
        uint256 _startTime, 
        uint256 _endTime, 
        uint256 _maxContrib,
        uint256 _ccoMax,
        string memory _ZAP_DETAILS
    ) external {
        
        require(!initialized, "CCOZap::initialized");
        require(_startTime > block.timestamp, "CCOZap:: Bad startTime");
        require(_endTime > _startTime, "CCOZap:: Bad endTime");
        require(_maxContrib > zapRate, "CCOZap:: Max too small");
        
        manager = _manager;
        token = _token;
        moloch = IMOLOCH(_moloch);
        zapRate = _zapRate;
        startTime = _startTime;
        endTime = _endTime;
        maxContrib = _maxContrib;
        ccoMax = _ccoMax;
        ccoFunds = 0;
        ZAP_DETAILS = _ZAP_DETAILS;
        initialized = true; 
    }
    
    /**
     * Contribute function for ppl to give to a CCO 
     * Caller submits a membership prooposal for loot to the CCO DAO
     * @param zapToken The CCO contribution token 
     * @param amount The amount of token user wants to give
     **/
    
    function contribute(address zapToken, uint256 amount) external nonReentrant returns (uint256) { 

        require(amount % 10**18  == 0, "CCOZap:: less than whoe token");
        require(amount >= zapRate && amount % zapRate  == 0, "CCOZap::no fractional shares");
        require(amount <= maxContrib && amount + contribution[msg.sender] <= maxContrib, "CCOZap:: give less");
        require(ccoFunds + amount <= ccoMax, "CCOZap:: CCO full");
        require(zapToken == token, "CCOZap::!token");
        require(block.timestamp >= startTime, "CCOZap:: !started");
        require(block.timestamp <= endTime, "CCOZap:: ended");
        
        uint256 proposalId = moloch.submitProposal(
            msg.sender,
            0,
            amount.div(zapRate).div(10**18), // loot shares
            amount,
            token,
            0,
            token,
            ZAP_DETAILS
        );
        
        ccoFunds += amount;
        zaps[proposalId] = Zap(msg.sender, token, false, amount);

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
        moloch.withdrawBalance(token, zapAmount); // withdraw zap funds from moloch
        zap.processed = true;

        IERC20ApproveTransfer(token).transfer(msg.sender, zapAmount); // redirect funds to zap proposer
        
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
        moloch.withdrawBalance(token, zapAmount); // withdraw zap funds from parent moloch
        zap.processed = true;
                
        IERC20ApproveTransfer(token).transfer(msg.sender, zapAmount); // redirect funds to zap proposer
        
        emit WithdrawZapProposal(msg.sender, proposalId);
    }
    
    /**
     * Easy way for the minion manager to update settings
     * @dev Uses timestamp to make sure the update can't be processed in same block its submitted
     * @dev Also prevents new updates until prior updates are implemented 
     * @param _manager The new manager, should be old managers address if sticking with same manager
     * @param _newToken The new CCO token to be used for contribute()
     * @param _zapRate The new ratio of tokens to loot shares
     * @param _ZAP_DETAILS The new details
     **/
    
    function updateZapMol( // manager adjusts zap proposal settings
        address _manager, 
        address _newToken, 
        uint256 _zapRate, 
        string calldata _ZAP_DETAILS
    ) external nonReentrant { 
        
        require(msg.sender == manager, "CCOZap::!manager");
        require(!updates[updateCount].implemented || updateCount == 0, "CCOZap::prior update !implemented");
        updateCount++;
        updates[updateCount] = Update(false, block.timestamp, _zapRate, _manager, _newToken, _ZAP_DETAILS);
        
        emit UpdateZapMol(_manager, _newToken, _zapRate, _ZAP_DETAILS);
    }
    
    /**
     * Way to implement a pending update
     * @dev Must be called at least one block later to allay security concerns
     * @param updateId The update to be implemented
     **/
    
    function implmentUpdate(uint256 updateId) external nonReentrant memberOnly returns (bool) {
        Update memory update = updates[updateId];
        require(!update.implemented, "ZapMol:: already implemented");
        require(updates[updateId-1].implemented, "ZapMol:: must implement prior update");
        require(block.timestamp > update.startBlock, "ZapMol:: must wait to implement");
    
        zapRate = update.newRate;
        manager = update.manager;
        token = update.token;
        ZAP_DETAILS = update.newDetails; 
        
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