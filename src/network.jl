function single_ground_all_pair_resistances{T}(a::SparseMatrixCSC, g::Graph, c::Vector{T}, cfg; 
                                                    exclude = Tuple{Int,Int}[], 
                                                    nodemap = Matrix{Float64}(), 
                                                    orig_pts = Vector{Int}(), 
                                                    polymap = Matrix{Float64}(),
                                                    hbmeta = RasterMeta())
    numpoints = size(c, 1)
    cc = connected_components(g)
    debug("Graph has $(size(a,1)) nodes, $numpoints focal points and $(length(cc)) connected components")
    resistances = -1 * ones(numpoints, numpoints) 

    cond = laplacian(a)

    volt = Vector{Float64}(size(g, 1))
    total = Int(numpoints * (numpoints-1) / 2)
    subsets = getindex.([cond], cc, cc)
    
    dat() = nodemap, polymap, hbmeta, orig_pts
    
    for (cid, comp) in enumerate(cc)
        csub = filter(x -> x in comp, c)
        idx = findin(c, csub)
        matrix = subsets[cid]
        for i = 1:size(csub, 1)
            X = vcat(pmap(x -> f(x, cfg, csub, idx, comp, matrix, i, dat, c), i+1:size(csub,1))...)
            for (i,j,v) in X
                resistances[i,j] = resistances[j,i] = v
            end
        end
    end
    for i = 1:size(resistances,1)
        resistances[i,i] = 0
    end
    
    resistances    
end

function f(j, cfg, csub, idx, comp, matrix, i, g, c)
        
    X = Tuple{Int,Int,Float64}[]
    pt1 = ingraph(comp, csub[i])
    pt2 = ingraph(comp, csub[j])
    curr = zeros(size(matrix, 1))
    curr[pt1] = -1
    curr[pt2] = 1
    info("Solving pt1 = $pt1, pt2 = $pt2")
    #volt = solve_linear_system(cfg, matrix, curr, M)
    volt = matrix \ curr
    nodemap, polymap, hbmeta, orig_pts = g()
    postprocess(volt, c, i, j, pt1, pt2, matrix, comp, cfg; 
                                            nodemap = nodemap,
                                            orig_pts = orig_pts, 
                                            polymap = polymap,
                                            hbmeta = hbmeta)
    v = volt[pt2] - volt[pt1]
    push!(X, (idx[i], idx[j], v))
end 

function solve_linear_system!(cfg, v, G, curr, M)
    if cfg["solver"] == "cg+amg"
        cg!(v, G, curr, M; tol = 1e-6, maxiter = 100000)
    end
    v
end
solve_linear_system(cfg, G, curr, M) = solve_linear_system!(cfg, zeros(curr), G, curr, M)

@inline function rightcc{T}(cc::Vector{Vector{T}}, c::T)
    for i in eachindex(cc)
        if c in cc[i]
            return i
        end
    end
end

@inline function ingraph{T}(cc::Vector{T}, c::T)
    findfirst(cc, c)
end

function laplacian(G::SparseMatrixCSC)
    G = G - spdiagm(diag(G))
    G = -G + spdiagm(vec(sum(G, 1)))
end

function postprocess(volt, cond, i, j, pt1, pt2, cond_pruned, cc, cfg; 
                                            nodemap = Matrix{Float64}(), 
                                            orig_pts = Vector{Int}(), 
                                            polymap = Vector{Float64}(),
                                            hbmeta = hbmeta)

    name = "_$(cond[i])_$(cond[j])"
    if cfg["data_type"] == "raster"
        name = "_$(Int(orig_pts[i]))_$(Int(orig_pts[j]))"
    end

    if cfg["write_volt_maps"] == "True"
        local_nodemap = zeros(Int, nodemap)
        idx = findin(nodemap, cc)
        local_nodemap[idx] = nodemap[idx]
        if isempty(polymap)
            idx = find(local_nodemap)
            local_nodemap[idx] = 1:length(idx)
        else
            local_polymap = zeros(local_nodemap)
            local_polymap[idx] = polymap[idx]
            local_nodemap = construct_node_map(local_nodemap, local_polymap)
        end
        write_volt_maps(name, volt, cc, cfg, hbmeta = hbmeta, nodemap = local_nodemap)
    end

    if cfg["write_cur_maps"] == "True"
        local_nodemap = zeros(Int, nodemap)
        idx = findin(nodemap, cc)
        local_nodemap[idx] = nodemap[idx]
        if isempty(polymap)
            idx = find(local_nodemap)
            local_nodemap[idx] = 1:length(idx)
        else
            local_polymap = zeros(local_nodemap)
            local_polymap[idx] = polymap[idx]
            local_nodemap = construct_node_map(local_nodemap, local_polymap)
        end
        write_cur_maps(cond_pruned, volt, [-9999.], cc, name, cfg; 
                                    nodemap = local_nodemap, 
                                    hbmeta = hbmeta)
    end
end

function compute_network(cfg)

    network_file = cfg["habitat_file"]
    point_file = cfg["point_file"]
    A = read_graph(cfg, network_file)
    g = Graph(A)
    scenario = cfg["scenario"]

    if scenario == "pairwise"

        fp = read_focal_points(point_file)
        resistances = single_ground_all_pair_resistances(A, g, fp, cfg)
        resistances_3col = compute_3col(resistances, fp)
        return resistances

    elseif scenario == "advanced"

        source_file = cfg["source_file"]
        ground_file = cfg["ground_file"]
        source_map = read_point_strengths(source_file)
        ground_map = read_point_strengths(ground_file)
        cc = connected_components(g)
        debug("There are $(size(A, 1)) points and $(length(cc)) connected components")
        voltages = advanced(cfg, A, g, source_map, ground_map, cc)

        return voltages

    end
end

function advanced(cfg, a::SparseMatrixCSC, g::Graph, source_map, ground_map, cc; 
                                                                    nodemap = Matrix{Float64}(), 
                                                                    policy = :keepall, 
                                                                    check_node = -1, 
                                                                    hbmeta = RasterMeta(), 
                                                                    src = 0, 
                                                                    polymap = Matrix{Float64}())

    mode = cfg["data_type"]
    is_network = mode == "network"
    sources = zeros(size(a, 1))
    grounds = zeros(size(a, 1))
    println("source map!")
    Base.print_matrix(STDOUT, source_map)
    println()
    if mode == "raster"
        (i1, j1, v1) = findnz(source_map)
        (i2, j2, v2) = findnz(ground_map)
        for i = 1:size(i1, 1)
            v = Int(nodemap[i1[i], j1[i]])
            if v != 0
                sources[v] += v1[i]
            end
        end
        for i = 1:size(i2, 1)
            v = Int(nodemap[i2[i], j2[i]])
            if v != 0
                grounds[v] += v2[i]
            end
        end
    else
        is_res = cfg["ground_file_is_resistances"]
        if is_res == "True"
            ground_map[:,2] = 1 ./ ground_map[:,2]
        end
        sources[Int.(source_map[:,1])] = source_map[:,2]
        grounds[Int.(ground_map[:,1])] = ground_map[:,2]
    end
    sources, grounds, finitegrounds = resolve_conflicts(sources, grounds, policy)
    @show sources
    volt = zeros(size(nodemap))
    ind = find(nodemap)
    f_local = Float64[]
    solver_called = false
    voltages = Float64[]
    outvolt = alloc_map(hbmeta) 
    outcurr = alloc_map(hbmeta)
    for c in cc
        if check_node != -1 && !(check_node in c)
            continue
        end
        a_local = laplacian(a[c, c])
        s_local = sources[c]
        g_local = grounds[c]
        if sum(s_local) == 0 || sum(g_local) == 0
            continue
        end
        if finitegrounds != [-9999.]
            f_local = finitegrounds[c]
        else
            f_local = finitegrounds
        end
        voltages = multiple_solver(cfg, a_local, g, s_local, g_local, f_local)
        solver_called = true
        if cfg["write_volt_maps"] == "True" && !is_network
            local_nodemap = zeros(Int, nodemap)
            idx = findin(nodemap, c)
            local_nodemap[idx] = nodemap[idx]
            if isempty(polymap)
                idx = find(local_nodemap)
                local_nodemap[idx] = 1:length(idx)
            else
                local_polymap = zeros(local_nodemap)
                local_polymap[idx] = polymap[idx]
                local_nodemap = construct_node_map(local_nodemap, local_polymap)
            end
            accum_voltages!(outvolt, voltages, local_nodemap, hbmeta)
        end
        if cfg["write_cur_maps"] == "True" && !is_network
            local_nodemap = zeros(Int, nodemap)
            idx = findin(nodemap, c)
            local_nodemap[idx] = nodemap[idx]
            if isempty(polymap)
                idx = find(local_nodemap)
                local_nodemap[idx] = 1:length(idx)
            else
                local_polymap = zeros(local_nodemap)
                local_polymap[idx] = polymap[idx]
                local_nodemap = construct_node_map(local_nodemap, local_polymap)
            end
            accum_currents!(outcurr, voltages, cfg, a_local, voltages, f_local, local_nodemap, hbmeta)
        end
        for i in eachindex(volt)
            if i in ind
                val = Int(nodemap[i])
                if val in c
                    idx = findfirst(x -> x == val, c)
                    volt[i] = voltages[idx] 
                end
            end
        end
    end

    name = src == 0 ? "" : "_$(Int(src))"
    if cfg["write_volt_maps"] == "True"
        if is_network
            write_volt_maps(name, voltages, collect(1:size(a,1)), cfg)
        else
            write_aagrid(outvolt, name, cfg, hbmeta, voltage = true)
        end
    end
    if cfg["write_cur_maps"] == "True"
        if is_network
            write_cur_maps(laplacian(a), voltages, finitegrounds, collect(1:size(a,1)), name, cfg)
        else
            write_aagrid(outcurr, name, cfg, hbmeta)
        end
    end

    if cfg["data_type"] == "network"
        v = [collect(1:size(a, 1))  voltages]
        return v
    end
    scenario = cfg["scenario"]
    if !solver_called
        return [-1.]
    end
    if scenario == "one-to-all" 
        idx = find(source_map)
        val = volt[idx] / source_map[idx]
        if val[1] ≈ 0
            return [-1.]
        else
            return val
        end
    elseif scenario == "all-to-one"
        return [0.]
    end

    return volt
end

function del_row_col(a, n::Int)
    l = size(a, 1)
    ind = union(1:n-1, n+1:l)
    a[ind, ind]
end

function resolve_conflicts(sources, grounds, policy)

    finitegrounds = similar(sources)
    l = size(sources, 1)

    finitegrounds = map(x -> x < Inf ? x : 0., grounds)
    if count(x -> x != 0, finitegrounds) == 0
        finitegrounds = [-9999.]
    end

    conflicts = falses(l)
    for i = 1:l
        conflicts[i] = sources[i] != 0 && grounds[i] != 0
    end

    if any(conflicts)
        if policy == :rmvsrc
            sources[find(conflicts)] = 0
        elseif policy == :rmvgnd
            grounds[find(conflicts)] = 0    
        elseif policy == :rmvall
            sources[find(conflicts)] = 0    
        end
    end

    infgrounds = map(x -> x == Inf, grounds)
    infconflicts = map((x,y) -> x > 0 && y > 0, infgrounds, sources)
    grounds[infconflicts] = 0


    sources, grounds, finitegrounds
end


function multiple_solver(cfg, a, g, sources, grounds, finitegrounds)

    asolve = deepcopy(a)
    if finitegrounds[1] != -9999
        asolve = a + spdiagm(finitegrounds, 0, size(a, 1), size(a, 1))
    end

    infgrounds = find(x -> x == Inf, grounds)
    deleteat!(sources, infgrounds)
    dst_del = Int[]
    append!(dst_del, infgrounds)
    r = collect(1:size(a, 1))
    deleteat!(r, dst_del)
    asolve = asolve[r, r]

    M = aspreconditioner(SmoothedAggregationSolver(asolve))
    volt = solve_linear_system(cfg, asolve, sources, M)

    # Replace the inf with 0
    voltages = zeros(length(volt) + length(infgrounds))
    k = 1
    for i = 1:size(voltages, 1)
        if i in infgrounds
            voltages[i] = 0
        else
            #voltages[i] = volt[1][k]
            voltages[i] = volt[k]
            k += 1
        end
    end
    voltages
end
