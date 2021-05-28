import "./ProxyFactory.sol";
import "./CCOZapMinion.sol";
import "./interfaces/IMOLOCH.sol";

contract ZapMinionFactory is CloneFactory, Ownable {
    
    address payable immutable public template; // fixed template for minion using eip-1167 proxy pattern
    
    event SummonMinion(address indexed minion, address manager, address indexed moloch, uint256 zapRate, uint256 startTime, uint256 endTime, uint256 maxContrib, uint256 ccoMax, string name);
    
    constructor(address payable _template) {
        template = _template;
    }
    
    
    function summonZapMinion(
        address _manager, // CCO manager
        address _moloch, // CCO DAO
        address _token, // CCO token
        uint256 _zapRate, // must be 1*10^18 or more 
        uint256 _startTime, // must be in the future
        uint256 _endTime, // must be after startTime
        uint256 _maxContrib, // limit on tokens a new member can submit
        uint256 _ccoMax, // limit on the total raised by the contract
        string memory _ZAP_DETAILS // Name of new minion 
    ) external returns (address) {
        
       (, uint256 shares,,,,) = IMOLOCH(_moloch).members(_manager);
       
       require(shares > 0, "ZAPFac::manager != member"); // Checks manager is a member of the moloch
       require(IMOLOCH(_moloch).tokenWhitelist(_token), "ZAPFac::token !whitelisted"); //Checks the token is whitelisted
        
        string memory name = "CCO Zap minion"; //For Subgraph Data
        
        //Summons new minion
        CCOZapMinion zapminion = CCOZapMinion(createClone(template));
        zapminion.init(_manager, _moloch, _token, _zapRate, _startTime, _endTime, _maxContrib, _ccoMax, _ZAP_DETAILS );
        
        emit SummonMinion(address(zapminion), _manager, _moloch, _zapRate, _startTime, _endTime, _maxContrib, _ccoMax, name);
        
        return(address(zapminion));
    }
    
}