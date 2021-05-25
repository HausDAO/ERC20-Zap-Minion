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
    address public token;
    uint256 public zapRate; // rate to convert ether into zap proposal share request (e.g., `10` = 10 shares per 1 ETH sent)
    uint256 public startTime; // beginning of when ppl can call the zapIt function 
    uint256 public endTime; // end of when ppl can call the zapIt function 
    uint256 public maxContrib; // max individual contribution in a CCO
    uint256 public ccoMax; // max total to be raised
    uint256 public ccoFunds; // tracking total contributed
    uint256 public updateCount; 
    string public ZAP_DETAILS; // general zap proposal details to attach
    bool private initialized; // internally tracks deployment under eip-1167 proxy pattern

    mapping(uint256 => Zap) public zaps; // proposalId => Zap
    mapping(uint256 => Update) public updates;
    mapping(address => uint256) public contribution; 
    
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
        require(!initialized, "ZapMol::initialized");
        require(isMember(_manager), "ZapMol:: manager != member");
        require(_startTime > block.timestamp, "ZapMol:: Bad startTime");
        require(_endTime > _startTime, "ZapMol:: Bad endTime");
        require(_maxContrib > zapRate, "ZapMol:: Max too small");
        
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
    
    function contribute(address zapToken, uint256 amount) external nonReentrant { // caller submits share proposal to moloch per zap rate and msg.value

        require(amount % 10**18  == 0, "ZapMol::token issue");
        require(amount >= zapRate && amount % zapRate  == 0, "ZapMol::no fractional shares");
        require(amount <= maxContrib && amount + contribution[msg.sender] <= maxContrib, "ZapMol:: give less");
        require(ccoFunds + amount <= ccoMax, "ZapMol:: CCO full");
        require(zapToken == token, "ZapMol::!token");
        require(block.timestamp >= startTime, "ZapMol:: !started");
        require(block.timestamp <= endTime, "ZapMol:: ended");
        
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
    }
    
    
    function cancelZapProposal(uint256 proposalId) external nonReentrant { // zap proposer can cancel zap & withdraw proposal funds 
        Zap storage zap = zaps[proposalId];
        require(msg.sender == zap.proposer, "ZapMol::!proposer");
        require(!zap.processed, "ZapMol::already processed");
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        require(!flags[0], "ZapMol::already sponsored");
        
        uint256 zapAmount = zap.zapAmount;
        moloch.cancelProposal(proposalId); // cancel zap proposal in parent moloch
        moloch.withdrawBalance(token, zapAmount); // withdraw zap funds from moloch
        zap.processed = true;

        IERC20ApproveTransfer(token).transfer(msg.sender, zapAmount); // redirect funds to zap proposer
        
        emit WithdrawZapProposal(msg.sender, proposalId);
    }
    
    function drawZapProposal(uint256 proposalId) external nonReentrant { // if proposal fails, withdraw back to proposer
        Zap storage zap = zaps[proposalId];
        require(msg.sender == zap.proposer, "ZapMol::!proposer");
        require(!zap.processed, "ZapMol::already processed");
        bool[6] memory flags = moloch.getProposalFlags(proposalId);
        require(flags[1] && !flags[2], "ZapMol::proposal passed");
        
        uint256 zapAmount = zap.zapAmount;
        moloch.withdrawBalance(token, zapAmount); // withdraw zap funds from parent moloch
        zap.processed = true;
                
        IERC20ApproveTransfer(token).transfer(msg.sender, zapAmount); // redirect funds to zap proposer
        
        emit WithdrawZapProposal(msg.sender, proposalId);
    }
    
    function updateZapMol( // manager adjusts zap proposal settings
        address _manager, 
        address _wrapper, 
        uint256 _zapRate, 
        string calldata _ZAP_DETAILS
    ) external nonReentrant memberOnly { 
        require(msg.sender == manager, "ZapMol::!manager");
        require(!updates[updateCount].implemented || updateCount == 0, "ZapMol::prior update !implemented");
        updateCount++;
        updates[updateCount] = Update(false, block.timestamp, _zapRate, _manager, _wrapper, _ZAP_DETAILS);
        
        emit UpdateZapMol(_manager, _wrapper, _zapRate, _ZAP_DETAILS);
    }
    
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
        revert("Don't send xDAI or eth here");
    }
}