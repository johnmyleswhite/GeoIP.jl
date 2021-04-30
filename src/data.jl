########################################
# Location structure
########################################
# It would be great to replace this with a real GIS package.
abstract type Point end
abstract type Point3D <: Point end

struct Location <: Point3D
    x::Float64
    y::Float64
    z::Float64
    datum::String

    function Location(x, y, z = 0, datum = "WGS84")
        if x === missing || y === missing
            return missing
        else
            return new(x, y, z, datum)
        end
    end
end

########################################
# Main structures
########################################
struct Locale{T}
    index::Vector{Int}
    locs::T
end

struct BlockRow{T}
    v4net::T
    geoname_id::Int
    location::Union{Location, Missing}
    registered_country_geoname_id::Union{Int, Missing}
    is_anonymous_proxy::Int
    is_satellite_provider::Int
    postal_code::Union{String, Missing}
    accuracy_radius::Union{Int, Missing}
end

function BlockRow(csvrow)
    net = IPNets.IPv4Net(csvrow.network)
    geoname_id = ismissing(csvrow.geoname_id) ? -1 : csvrow.geoname_id
    location = Location(csvrow.longitude, csvrow.latitude)
    registered_country_geoname_id = csvrow.registered_country_geoname_id
    accuracy_radius = get(csvrow, :accuracy_radius, missing)
    postal_code = csvrow.postal_code

    BlockRow(
        net,
        geoname_id,
        location,
        registered_country_geoname_id,
        csvrow.is_anonymous_proxy,
        csvrow.is_satellite_provider,
        postal_code,
        accuracy_radius
    )
end

struct DB{T1, T2 <: Locale}
    index::Vector{T1}
    blocks::Vector{BlockRow{T1}}
    locs::Vector{T2}
    localeid::Int
    ldict::Dict{Symbol, Int}
end

Base.broadcastable(db::DB) = Ref(db)
function setlocale(db::DB, localename)
    if localename in keys(db.ldict)
        return DB(db.index, db.blocks, db.locs, db.ldict[localename], db.ldict)
    else
        @warn "Unable to find locale $localename"
        return db
    end
end

# Path to directory with data, can define GEOIP_DATADIR to override
# the default (useful for testing with a smaller test set)
function getdatadir(datadir)
    isempty(datadir) || return datadir
    haskey(ENV, "GEOIP_DATADIR") ?  ENV["GEOIP_DATADIR"] : datadir
end

function getzipfile(zipfile)
    isempty(zipfile) || return zipfile
    haskey(ENV, "GEOIP_ZIPFILE") ? ENV["GEOIP_ZIPFILE"] : zipfile
end

getlocale(x::Pair) = x
function getlocale(x::Symbol)
    if x == :en
        return :en => r"Locations-en.csv$"
    elseif x == :de
        return :de => r"Locations-de.csv$"
    elseif x == :ru
        return :ru => r"Locations-ru.csv$"
    elseif x == :ja
        return :ja => r"Locations-ja.csv$"
    elseif x == :es
        return :es => r"Locations-es.csv$"
    elseif x == :fr
        return :fr => r"Locations-fr.csv$"
    elseif x == :pt_br
        return :pt_br => r"Locations-pt-BR.csv$"
    elseif x == :zh_cn
        return :zh_cn => r"Locations-zh_cn.csv$"
    end
end

function loadgz(datadir, blockcsvgz, citycsvgz)
    blockfile = joinpath(datadir, blockcsvgz)
    locfile = joinpath(datadir, citycsvgz)

    isfile(blockfile) || throw(ArgumentError("Unable to find blocks file in $(blockfile)"))
    isfile(locfile) || throw(ArgumentError("Unable to find locations file in $(locfile)"))
    
    local blocks
    local locs
    try
        blocks = GZip.open(blockfile, "r") do stream
            CSV.File(read(stream); types = Dict(:postal_code => String))
        end
        locs = GZip.open(locfile, "r") do stream
            CSV.File(read(stream))
        end
    catch
        @error "Geolocation data cannot be read. Data directory may be corrupt..."
        rethrow()
    end

    return blocks, locs, Dict(:en => 1)
end

function loadzip(datadir, zipfile, locales)
    zipfile = joinpath(datadir, zipfile)
    isfile(zipfile) || throw(ArgumentError("Unable to find data file in $(zipfile)"))
    
    r = ZipFile.Reader(zipfile)
    ldict = Dict{Symbol, Int}()
    locid = 1
    local blocks
    locs = []
    try
        for f in r.files
            for (l, s) in locales
                if occursin(s, f.name)
                    v = Vector{UInt8}(undef, f.uncompressedsize)
                    ls = read!(f, v) |> CSV.File
                    push!(locs, ls)
                    ldict[l] = locid
                    locid += 1
                end
            end
            if occursin(r"Blocks-IPv4.csv$", f.name)
                v = Vector{UInt8}(undef, f.uncompressedsize)
                blocks = read!(f, v) |> x -> CSV.File(x; types = Dict(:postal_code => String))
            end
        end
    catch
        @error "Geolocation data cannot be read. Data directory may be corrupt..."
        rethrow()
    finally
        close(r)
    end

    return blocks, locs, ldict
end

"""
    load(; datadir, zipfile, blockcsvgz, citycsvgz)

Load GeoIP database from compressed CSV file or files. If `zipfile` argument is provided then `load` tries to load data from that file, otherwise it will try to load data from `blockcsvgz` and `citycsvgz`. By default `blockcsvgz` equals to `"GeoLite2-City-Blocks-IPv4.csv.gz"` and `citycsvgz` equals to `"GeoLite2-City-Locations-en.csv.gz"`. `datadir` defines where data files are located and can be either set as an argument or read from the `ENV` variable `GEOIP_DATADIR`. In the same way if `ENV` variable `GEOIP_ZIPFILE` is set, then it is used for determining `zipfile` argument.
"""
function load(; zipfile = "",
                datadir = "",
                locales = [:en],
                deflocale = :en,
                blockcsvgz = "GeoLite2-City-Blocks-IPv4.csv.gz",
                citycsvgz  = "GeoLite2-City-Locations-en.csv.gz")
    datadir = getdatadir(datadir)
    zipfile = getzipfile(zipfile)
    blocks, locs, ldict = if isempty(zipfile)
        loadgz(datadir, blockcsvgz, citycsvgz)
    else
        locales = getlocale.(locales)
        loadzip(datadir, zipfile, locales)
    end

    blockdb = BlockRow.(blocks)
    sort!(blockdb, by = x -> x.v4net)
    index = map(x -> x.v4net, blockdb)
    locsdb = map(locs) do loc
        ldb = collect(loc)
        sort!(ldb, by = x -> x.geoname_id)
        lindex = map(x -> x.geoname_id, ldb)
        Locale(lindex, ldb)
    end

    localeid = if deflocale in keys(ldict)
        ldict[deflocale]
    else
        cd = collect(d)
        idx = findfirst(x -> x[2] == 1, cd)
        locname = cd[idx][1]
        @warn "Default locale $deflocale was not found, using locale $locname"
        1
    end

    return DB(index, blockdb, locsdb, localeid, ldict)
end
