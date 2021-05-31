import "./ProxyFactory.sol";
import "./CCOZapMinion.sol";
import "./interfaces/IMOLOCH.sol";

contract ZapMinionFactory is CloneFactory, Ownable {
    
    address payable immutable public template; // fixed template for minion using eip-1167 proxy pattern
    
    event SummonMinion(address indexed minion, address indexed moloch, uint256 zapRate, uint256 startTime, uint256 endTime, uint256 maxContrib, uint256 ccoMax, string name);
    
    constructor(address payable _template) {
        template = _template;
    }
    
    
    function summonZapMinion(
        address _moloch, // CCO DAO
        address _contribToken, // CCO token
        address _projToken,
        uint256 _zapRate, // must be 1*10^18 or more 
        uint256 _startTime, // must be in the future
        uint256 _endTime, // must be after startTime
        uint256 _unlockTime, // must be after end time 
        uint256 _maxContrib, // limit on tokens a new member can submit
        uint256 _ccoMax // limit on the total raised by the contract
    ) external returns (address) {
        
       require(IMOLOCH(_moloch).tokenWhitelist(_contribToken), "ZAPFac::contrib token !whitelisted"); //Checks the token is whitelisted
       require(IMOLOCH(_moloch).tokenWhitelist(_projToken), "ZAPFac:: proj token !whitelisted"); //Checks the token is whitelisted    
       
       string memory name = "CCO Zap minion"; //For Subgraph Data
        
        //Summons new minion
        CCOZapMinion zapminion = CCOZapMinion(createClone(template));
        zapminion.init(_moloch, _contribToken, _projToken, _zapRate, _startTime, _endTime, _unlockTime, _maxContrib, _ccoMax);
        
        emit SummonMinion(address(zapminion), _moloch, _zapRate, _startTime, _endTime, _maxContrib, _ccoMax, name);

        return(address(zapminion));
    }
    
}