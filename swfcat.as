/* Flash parameters. These can change how the program runs from the outside.
 * They can be set as a URL query string, for example:
 *      http://www.example.com/swfcat.swf?facilitator=127.0.0.1:9002&debug=1
 * or in the HTML markup for the embedding of the movie:
 *      <object>
 *          <param name="movie" value="http://www.example.com/swfcat.swf">
 *          <param name="flashvars" value="facilitator=127.0.0.1:9002&debug=1">
 *          <embed src="http://www.example.com/swfcat.swf"
 *                 flashvars="facilitator=127.0.0.1:9002&debug=1"></embed>
 *      </object>
 *
 * debug=1
 * If set (to any value), show verbose terminal-like output instead of the
 * badge.
 *
 * facilitator=<HOST>:<PORT>
 * The address of the facilitator to use. By default it is
 * DEFAULT_FACILITATOR_ADDR. Both <HOST> and <PORT> must be present.
 *
 * max_clients=<NUM>
 * How many clients to serve concurrently. The default is
 * DEFAULT_MAX_NUM_PROXY_PAIRS.
 *
 * facilitator_poll_interval=<FLOAT>
 * How often to poll the facilitator, in seconds. The default is
 * DEFAULT_FACILITATOR_POLL_INTERVAL. There is a sanity-check minimum of 1.0 s.
 * 
 * ratelimit=<FLOAT>(<UNIT>)?|off
 * What rate to limit all proxy traffic combined to. The special value "off"
 * disables the limit. The default is DEFAULT_RATE_LIMIT. There is a
 * sanity-check minimum of "10K".
 *
 * client=1
 * If set (to any value), run in client RTMFP mode. In this mode, rather than
 * connecting to a facilitator and attempting to serve clients, swfcat starts an
 * RTMFP socket and connects to a local address (to the connector, to be exact).
 * See README for more on running in client RTMFP mode. No argument is required
 * to use RTMFP when in the usual server mode.
 *
 * local=<HOST>:<PORT>
 * When in client RTMFP mode (client=1), connect to this local address. The
 * default is DEFAULT_LOCAL_TOR_CLIENT_ADDR.
 */

package
{
    import flash.display.Sprite;
    import flash.display.StageAlign;
    import flash.display.StageScaleMode;
    import flash.events.Event;
    import flash.events.IOErrorEvent;
    import flash.events.SecurityErrorEvent;
    import flash.external.ExternalInterface;
    import flash.net.Socket;
    import flash.net.URLLoader;
    import flash.net.URLLoaderDataFormat;
    import flash.net.URLRequest;
    import flash.net.URLRequestMethod;
    import flash.net.URLVariables;
    import flash.text.TextField;
    import flash.text.TextFormat;
    import flash.utils.setTimeout;

    public class swfcat extends Sprite
    {
        private const RTMFP_URL:String = "rtmfp://tor-facilitator.bamsoftware.com";

        private const DEFAULT_FACILITATOR_ADDR:Object = {
            host: "tor-facilitator.bamsoftware.com",
            port: 9002
        };

        /* Local Tor client to use in case of RTMFP connection. */
        private const DEFAULT_LOCAL_TOR_CLIENT_ADDR:Object = {
            host: "127.0.0.1",
            port: 9002
        };

        private const DEFAULT_MAX_NUM_PROXY_PAIRS:uint = 10;

        /* In seconds. */
        private const DEFAULT_FACILITATOR_POLL_INTERVAL:Number = 10.0;
        private const MIN_FACILITATOR_POLL_INTERVAL:Number = 1.0;

        // Bytes per second. Set to undefined to disable limit.
        public static const DEFAULT_RATE_LIMIT:Number = undefined;
        public static const MIN_RATE_LIMIT:Number = 10 * 1024;
        // Seconds.
        private static const RATE_LIMIT_HISTORY:Number = 5.0;

        /* TextField for debug output. */
        private var output_text:TextField;

        /* UI shown when debug is off. */
        private var badge:Badge;

        /* Proxy pairs currently connected (up to max_num_proxy_pairs). */
        private var proxy_pairs:Array;

        public var debug:Boolean;
        private var fac_addr:Object;
        private var max_num_proxy_pairs:uint;
        private var facilitator_poll_interval:Number;
        private var local_addr:Object;

        public var rate_limit:RateLimit;

        public function puts(s:String):void
        {
            if (output_text) {
                output_text.appendText(s + "\n");
                output_text.scrollV = output_text.maxScrollV;
            }
        }

        public function swfcat()
        {
            // Absolute positioning.
            stage.scaleMode = StageScaleMode.NO_SCALE;
            stage.align = StageAlign.TOP_LEFT;

            badge = new Badge();

            proxy_pairs = [];

            // Wait until the query string parameters are loaded.
            this.loaderInfo.addEventListener(Event.COMPLETE, loaderinfo_complete);
        }

        private function loaderinfo_complete(e:Event):void
        {
            var tmp:*;

            debug = this.loaderInfo.parameters["debug"];

            if (debug || this.loaderInfo.parameters["client"]) {
                output_text = new TextField();
                output_text.width = stage.stageWidth;
                output_text.height = stage.stageHeight;
                output_text.background = true;
                output_text.backgroundColor = 0x001f0f;
                output_text.textColor = 0x44cc44;
                addChild(output_text);
            } else {
                addChild(badge);
            }

            puts("Parameters loaded.");

            fac_addr = get_param_addr("facilitator", DEFAULT_FACILITATOR_ADDR);
            if (!fac_addr) {
                puts("Error: Facilitator spec must be in the form \"host:port\".");
                return;
            }

            tmp = get_param_number("max_clients", DEFAULT_MAX_NUM_PROXY_PAIRS);
            if (tmp == null || tmp < 0) {
                puts("Error: max_clients must be a nonnegative integer.");
                return;
            }
            max_num_proxy_pairs = uint(tmp);

            tmp = get_param_timespec("facilitator_poll_interval", DEFAULT_FACILITATOR_POLL_INTERVAL);
            if (tmp == null || tmp < MIN_FACILITATOR_POLL_INTERVAL) {
                puts("Error: facilitator_poll_interval must be a nonnegative number at least " + MIN_FACILITATOR_POLL_INTERVAL + ".");
                return;
            }
            facilitator_poll_interval = Number(tmp);

            if (this.loaderInfo.parameters["ratelimit"] == "off")
                tmp = undefined;
            else
                tmp = get_param_byte_count("ratelimit", DEFAULT_RATE_LIMIT);
            if (tmp === undefined) {
                /* No rate limit. */
            } else if (tmp == null || tmp < MIN_FACILITATOR_POLL_INTERVAL) {
                puts("Error: ratelimit must be a nonnegative number at least " + MIN_RATE_LIMIT + ".");
                return;
            }
            if (tmp)
                rate_limit = new BucketRateLimit(Number(tmp) * RATE_LIMIT_HISTORY, RATE_LIMIT_HISTORY);
            else
                rate_limit = new RateUnlimit();

            local_addr = get_param_addr("local", DEFAULT_LOCAL_TOR_CLIENT_ADDR);
            if (!local_addr) {
                puts("Error: Local spec must be in the form \"host:port\".");
                return;
            }

            if (this.loaderInfo.parameters["client"])
                client_main();
            else
                proxy_main();
        }

        /* Get an address structure from the given movie parameter, or the given
           default. Returns null on error. */
        private function get_param_addr(param:String, default_addr:Object):Object
        {
            var spec:String;

            spec = this.loaderInfo.parameters[param];
            if (spec)
                return parse_addr_spec(spec);
            else
                return default_addr;
        }

        /* Get a number from the given movie parameter, or the given default.
           Returns null on error. First check for a null return, and then call
           uint or whatever on the return value if no error. */
        private function get_param_number(param:String, default_val:Number):Object
        {
            var spec:String;
            var val:Number;

            spec = this.loaderInfo.parameters[param];
            if (spec) {
                val = Number(spec);
                if (isNaN(val))
                    return null;
                else
                    return val;
            } else {
                return default_val;
            }
        }

        /* Get a floating-point number of seconds from a time specification. The
           only time specification format is a decimal number of seconds.
           Returns null on error. */
        private function get_param_timespec(param:String, default_val:Number):Object
        {
            return get_param_number(param, default_val);
        }

        /* Get a count of bytes from a string specification like "100" or
           "1.3m". Returns null on error. */
        private function get_param_byte_count(param:String, default_val:Number):Object
        {
            var spec:String;

            spec = this.loaderInfo.parameters[param];
            if (spec)
                return parse_byte_count(spec);
            else
                return default_val;
        }

        /* The main logic begins here, after start-up issues are taken care of. */
        private function proxy_main():void
        {
            var fac_url:String;
            var loader:URLLoader;

            if (proxy_pairs.length >= max_num_proxy_pairs) {
                setTimeout(proxy_main, uint(facilitator_poll_interval * 1000));
                return;
            }

            loader = new URLLoader();
            /* Get the application/x-www-form-urlencoded values. */
            loader.dataFormat = URLLoaderDataFormat.VARIABLES;
            loader.addEventListener(Event.COMPLETE, fac_complete);
            loader.addEventListener(IOErrorEvent.IO_ERROR, function (e:IOErrorEvent):void {
                puts("Facilitator: I/O error: " + e.text + ".");
            });
            loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function (e:SecurityErrorEvent):void {
                puts("Facilitator: security error: " + e.text + ".");
            });

            fac_url = "http://" + encodeURIComponent(fac_addr.host)
                + ":" + encodeURIComponent(fac_addr.port) + "/";
            puts("Facilitator: connecting to " + fac_url + ".");
            loader.load(new URLRequest(fac_url));
        }

        private function fac_complete(e:Event):void
        {
            var loader:URLLoader;
            var client_spec:String;
            var relay_spec:String;
            var proxy_pair:Object;

            setTimeout(proxy_main, uint(facilitator_poll_interval * 1000));

            loader = e.target as URLLoader;
            client_spec = loader.data.client;
            if (client_spec == "") {
                puts("No clients.");
                return;
            } else if (!client_spec) {
                puts("Error: missing \"client\" in response.");
                return;
            }
            relay_spec = loader.data.relay;
            if (!relay_spec) {
                puts("Error: missing \"relay\" in response.");
                return;
            }
            puts("Facilitator: got client:\"" + client_spec + "\" "
                + "relay:\"" + relay_spec + "\".");

            try {
                proxy_pair = make_proxy_pair(client_spec, relay_spec);
            } catch (e:ArgumentError) {
                puts("Error: " + e);
                return;
            }
            proxy_pairs.push(proxy_pair);
            proxy_pair.addEventListener(Event.COMPLETE, function(e:Event):void {
                proxy_pair.log("Complete.");
                /* Delete from the list of active proxy pairs. */
                proxy_pairs.splice(proxy_pairs.indexOf(proxy_pair), 1);
                badge.proxy_end();
            });
            proxy_pair.connect();

            badge.proxy_begin();
        }

        private function client_main():void
        {
            var rs:RTMFPSocket;

            puts("Making RTMFP socket.");
            rs = new RTMFPSocket(RTMFP_URL);
            rs.addEventListener(Event.COMPLETE, function (e:Event):void {
                puts("Got RTMFP id " + rs.id);
                register(rs);
            });
            rs.addEventListener(RTMFPSocket.ACCEPT_EVENT, client_accept);

            rs.listen();
        }

        private function client_accept(e:Event):void {
            var rs:RTMFPSocket;
            var s_t:Socket;
            var proxy_pair:ProxyPair;

            rs = e.target as RTMFPSocket;
            s_t = new Socket();

            puts("Got RTMFP connection from " + rs.peer_id);

            proxy_pair = new ProxyPair(this, rs, function ():void {
                /* Do nothing; already connected. */
            }, s_t, function ():void {
                s_t.connect(local_addr.host, local_addr.port);
            });
            proxy_pair.connect();
        }

        private function register(rs:RTMFPSocket):void {
            var fac_url:String;
            var loader:URLLoader;
            var request:URLRequest;

            loader = new URLLoader();
            loader.addEventListener(Event.COMPLETE, function (e:Event):void {
                puts("Facilitator: registered.");
            });
            loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function (e:SecurityErrorEvent):void {
                puts("Facilitator: security error: " + e.text + ".");
                rs.close();
            });
            loader.addEventListener(IOErrorEvent.IO_ERROR, function (e:IOErrorEvent):void {
                puts("Facilitator: I/O error: " + e.text + ".");
                rs.close();
            });

            fac_url = "http://" + encodeURIComponent(fac_addr.host)
                + ":" + encodeURIComponent(fac_addr.port) + "/";
            request = new URLRequest(fac_url);
            request.method = URLRequestMethod.POST;
            request.data = new URLVariables();
            request.data["client"] = rs.id;

            puts("Facilitator: connecting to " + fac_url + ".");
            loader.load(request);
        }

        private function make_proxy_pair(client_spec:String, relay_spec:String):ProxyPair
        {
            var proxy_pair:ProxyPair;
            var addr_c:Object;
            var addr_r:Object;
            var s_c:*;
            var s_r:Socket;

            addr_r = swfcat.parse_addr_spec(relay_spec);
            if (!addr_r)
                throw new ArgumentError("Relay spec must be in the form \"host:port\".");

            addr_c = swfcat.parse_addr_spec(client_spec);
            if (addr_c) {
                s_c = new Socket();
                s_r = new Socket();
                proxy_pair = new ProxyPair(this, s_c, function ():void {
                    s_c.connect(addr_c.host, addr_c.port);
                }, s_r, function ():void {
                    s_r.connect(addr_r.host, addr_r.port);
                });
                proxy_pair.set_name("<" + addr_c.host + ":" + addr_c.port + ","
                    + addr_r.host + ":" + addr_r.port + ">");
                return proxy_pair;
            }

            if (client_spec.match(/^[0-9A-Fa-f]{64}$/)) {
                s_c = new RTMFPSocket(RTMFP_URL);
                s_r = new Socket();
                proxy_pair = new ProxyPair(this, s_c, function ():void {
                    s_c.connect(client_spec);
                }, s_r, function ():void {
                    s_r.connect(addr_r.host, addr_r.port);
                });
                proxy_pair.set_name("<" + client_spec.substr(0, 4) + "...,"
                    + addr_r.host + ":" + addr_r.port + ">");
                return proxy_pair;
            }

            throw new ArgumentError("Can't parse client spec \"" + client_spec + "\".");
        }

        /* Parse an address in the form "host:port". Returns an Object with
           keys "host" (String) and "port" (int). Returns null on error. */
        private static function parse_addr_spec(spec:String):Object
        {
            var parts:Array;
            var addr:Object;

            parts = spec.split(":", 2);
            if (parts.length != 2 || !parseInt(parts[1]))
                return null;
            addr = {}
            addr.host = parts[0];
            addr.port = parseInt(parts[1]);

            return addr;
        }

        /* Parse a count of bytes. A suffix of "k", "m", or "g" (or uppercase)
           does what you would think. Returns null on error. */
        private static function parse_byte_count(spec:String):Object
        {
            const UNITS:Object = {
                k: 1024, m: 1024 * 1024, g: 1024 * 1024 * 1024,
                K: 1024, M: 1024 * 1024, G: 1024 * 1024 * 1024
            };
            var count:Number, units:Object;
            var matches:Array;

            matches = spec.match(/^(\d+(?:\.\d*)?)(\w*)$/);
            if (matches == null)
                return null;

            count = Number(matches[1]);
            if (isNaN(count))
                return null;

            if (matches[2] == "") {
                units = 1;
            } else {
                units = UNITS[matches[2]];
                if (units == null)
                    return null;
            }

            return count * Number(units);
        }
    }
}

import flash.events.MouseEvent;
import flash.net.navigateToURL;
import flash.net.URLRequest;
import flash.text.TextField;
import flash.text.TextFormat;
import flash.utils.getTimer;

class Badge extends flash.display.Sprite
{
    private const FLASHPROXY_INFO_URL:String = "https://crypto.stanford.edu/flashproxy/";

    /* Number of proxy pairs currently connected. */
    private var num_proxy_pairs:int = 0;
    /* Number of proxy pairs ever connected. */
    private var total_proxy_pairs:int = 0;

    [Embed(source="badge.png")]
    private var BadgeImage:Class;
    private var tot_client_count_tf:TextField;
    private var tot_client_count_fmt:TextFormat;
    private var cur_client_count_tf:TextField;
    private var cur_client_count_fmt:TextFormat;

    public function Badge()
    {
        /* Setup client counter for badge. */
        tot_client_count_fmt = new TextFormat();
        tot_client_count_fmt.color = 0xFFFFFF;
        tot_client_count_fmt.align = "center";
        tot_client_count_fmt.font = "courier-new";
        tot_client_count_fmt.bold = true;
        tot_client_count_fmt.size = 10;
        tot_client_count_tf = new TextField();
        tot_client_count_tf.width = 20;
        tot_client_count_tf.height = 17;
        tot_client_count_tf.background = false;
        tot_client_count_tf.defaultTextFormat = tot_client_count_fmt;
        tot_client_count_tf.x=47;
        tot_client_count_tf.y=0;

        cur_client_count_fmt = new TextFormat();
        cur_client_count_fmt.color = 0xFFFFFF;
        cur_client_count_fmt.align = "center";
        cur_client_count_fmt.font = "courier-new";
        cur_client_count_fmt.bold = true;
        cur_client_count_fmt.size = 10;
        cur_client_count_tf = new TextField();
        cur_client_count_tf.width = 20;
        cur_client_count_tf.height = 17;
        cur_client_count_tf.background = false;
        cur_client_count_tf.defaultTextFormat = cur_client_count_fmt;
        cur_client_count_tf.x=47;
        cur_client_count_tf.y=6;

        addChild(new BadgeImage());
        addChild(tot_client_count_tf);
        addChild(cur_client_count_tf);

        /* Update the client counter on badge. */
        update_client_count();

        addEventListener(MouseEvent.CLICK, mouse_clicked);
    }

    public function proxy_begin():void
    {
        num_proxy_pairs++;
        total_proxy_pairs++;
        update_client_count();
    }

    public function proxy_end():void
    {
        num_proxy_pairs--;
        update_client_count();
    }

    private function update_client_count():void
    {
        /* Update total client count. */
        if (String(total_proxy_pairs).length == 1)
            tot_client_count_tf.text = "0" + String(total_proxy_pairs);
        else
            tot_client_count_tf.text = String(total_proxy_pairs);

        /* Update current client count. */
        cur_client_count_tf.text = "";
        for(var i:Number = 0; i < num_proxy_pairs; i++)
            cur_client_count_tf.appendText(".");
    }

    /* Show a web page with detailed information when the badge is clicked. */
    private function mouse_clicked(e:MouseEvent):void
    {
        try {
            navigateToURL(new URLRequest(FLASHPROXY_INFO_URL));
        } catch (err:Error) {
        }
    }
}

class RateLimit
{
    public function RateLimit()
    {
    }

    public function update(n:Number):Boolean
    {
        return true;
    }

    public function when():Number
    {
        return 0.0;
    }

    public function is_limited():Boolean
    {
        return false;
    }
}

class RateUnlimit extends RateLimit
{
    public function RateUnlimit()
    {
    }

    public override function update(n:Number):Boolean
    {
        return true;
    }

    public override function when():Number
    {
        return 0.0;
    }

    public override function is_limited():Boolean
    {
        return false;
    }
}

class BucketRateLimit extends RateLimit
{
    private var amount:Number;
    private var capacity:Number;
    private var time:Number;
    private var last_update:uint;

    public function BucketRateLimit(capacity:Number, time:Number)
    {
        this.amount = 0.0;
        /* capacity / time is the rate we are aiming for. */
        this.capacity = capacity;
        this.time = time;
        this.last_update = getTimer();
    }

    private function age():void
    {
        var now:uint;
        var delta:Number;

        now = getTimer();
        delta = (now - last_update) / 1000.0;
        last_update = now;

        amount -= delta * capacity / time;
        if (amount < 0.0)
            amount = 0.0;
    }

    public override function update(n:Number):Boolean
    {
        age();
        amount += n;

        return amount <= capacity;
    }

    public override function when():Number
    {
        age();
        return (amount - capacity) / (capacity / time);
    }

    public override function is_limited():Boolean
    {
        age();
        return amount > capacity;
    }
}
