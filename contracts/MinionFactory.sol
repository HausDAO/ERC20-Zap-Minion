import "./ProxyFactory";
import "./CCOZapMinion";

contract ZapMinionFactory is CloneFactory, Ownable {
    
    address payable immutable public template; // fixed template for minion using eip-1167 proxy pattern
    
    event SummonMinion(address indexed minion, address manager, address indexed moloch, uint256 zapRate, uint256 startTime, uint256 endTime, uint256 maxContrib, uint256 ccoMax, string name);
    
    constructor(address payable _template) {
        template = _template;
    }
    
    // @DEV - zapRate should be entered in whole ETH or xDAI
    function summonZapMinion(
        address _manager, 
        address _moloch, 
        address _token, 
        uint256 _zapRate, 
        uint256 _startTime, 
        uint256 _endTime, 
        uint256 _maxContrib,
        uint256 _ccoMax,
        string memory _ZAP_DETAILS
    ) external returns (address) {
        
        string memory name = "Zap minion";
        CCOZapMinion zapminion = CCOZapMinion(createClone(template));
        zapminion.init(_manager, _moloch, _token, _zapRate, _startTime, _endTime, _maxContrib, _ccoMax, _ZAP_DETAILS );
        
        emit SummonMinion(address(zapminion), _manager, _moloch, _zapRate, _startTime, _endTime, _maxContrib, _ccoMax, name);
        
        return(address(zapminion));
    }
    
}