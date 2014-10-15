type APISpec
    md::Module
    fn::Function
    resp_json::Bool
    resp_headers::Dict
end

type APIResponder
    ctx::Context
    sock::Socket
    endpoints::Dict{String, APISpec}

    function APIResponder(addr::String, ctx::Context=Context(), bind::Bool=true)
        a = new()
        a.ctx = ctx
        a.sock = Socket(ctx, REP)
        a.endpoints = Dict{String, APISpec}()
        if bind
            ZMQ.bind(a.sock, addr)
        else
            ZMQ.connect(a.sock, addr)
        end
        a
    end
    APIResponder(ip::IPv4, port::Int, ctx::Context=Context()) = APIResponder("tcp://$ip:$port", ctx)
end

# register a function as API call
# TODO: validate method belongs to module?
function register(conn::APIResponder, m::Module, f::Function; 
                  resp_json::Bool=false, 
                  resp_headers::Dict=Dict{String,String}())
    endpt = string(f)
    debug("registering endpoint [$endpt]")
    conn.endpoints[endpt] = APISpec(m, f, resp_json, resp_headers)
end

function respond(conn::APIResponder, code::Int, headers::Dict, resp::Any)
    msg = Dict{String,Any}()
    msg["code"] = code
    (length(headers) > 0) && (msg["hdrs"] = headers)
    msg["data"] = resp
    msgstr = JSON.json(msg)
    debug("sending response [$msgstr]")
    ZMQ.send(conn.sock, Message(msgstr))
end

respond(conn::APIResponder, api::Nullable{APISpec}, status::Symbol, resp::Any=nothing) =
    respond(conn, ERR_CODES[status][1], get_hdrs(api), get_resp(api, status, resp))

function call_api(api::APISpec, conn::APIResponder, args::Array, data::Dict{Symbol,Any})
    try
        result = api.fn(args...; data...)
        respond(conn, Nullable(api), :success, result)
    catch e
        respond(conn, Nullable(api), :api_exception)
    end
end

function get_resp(api::Nullable{APISpec}, status::Symbol, resp::Any=nothing)
    st = ERR_CODES[status]
    stcode = st[2]
    stresp = ((stcode != 0) && (resp === nothing)) ? "$(st[3]) : $(st[2])" : resp

    if !isnull(api) && get(api).resp_json
        return Dict{String, Any}(
                        "code" => stcode,
                        "data" => stresp 
                    )
    else
        return stresp
    end
end

get_hdrs(api::Nullable{APISpec}) = !isnull(api) ? get(api).resp_headers : Dict{String,String}()

args(msg::Dict) = get(msg, "args", [])
data(msg::Dict) = convert(Dict{Symbol,Any}, get(msg, "vargs", Dict{Symbol,Any}()))

# start processing as a server
function process(conn::APIResponder)
    debug("processing...")
    while true
        msg = JSON.parse(bytestring(ZMQ.recv(conn.sock)))

        cmd = get(msg, "cmd", "")
        debug("received request [$cmd]")

        if !haskey(conn.endpoints, cmd)
            respond(conn, Nullable{APISpec}(), :invalid_api)
            continue
        end

        try
            call_api(conn.endpoints[cmd], conn, args(msg), data(msg))
        catch e
            err("exception $e")
            respond(conn, Nullable(conn.endpoints[cmd]), :invalid_data)
        end
    end
end
