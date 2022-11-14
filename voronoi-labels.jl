## Goal, implement the label picking algorithm 
# from 
# https://observablehq.com/@harrystevens/directly-labelling-lines
# for Makie plots...
# Lots of helpful stuff here...
# https://github.com/MakieOrg/Makie.jl/blob/33c48deb946454e655601a0775f92867a8617521/src/makielayout/blocks/legend.jl
# more info here...
# https://talk.observablehq.com/t/placement-of-diagram-labels/2207

## # regarding 
# we need to edit it a little bit to try out a new idea.
using Revise

# This package is really helpful for the Voronoi cells 
# https://github.com/JuliaGeometry/VoronoiCells.jl
## Setup and packages
using VoronoiCells, CairoMakie, GeometryBasics, Statistics, LinearAlgebra, DataStructures

## Make a plot to start 
using Random
Random.seed!(1)
f = lines(cumsum(randn(100)), label="Direct",
  color=Cycled(1), marker=:rect)
lines!(f.axis, cumsum(randn(100)), label="Labels",
  color=Cycled(2))
lines!(f.axis, cumsum(randn(100)), label="Are Great",
  color=Cycled(3))
lines!(f.axis, cumsum(randn(100)), label="Are Great",
  color=Cycled(4))
lines!(f.axis, cumsum(randn(100)), label="Are Great",
  color=Cycled(5))

function _getpts(plt::Makie.Scatter)
  Point{2,Float32}.(plt[1][])
end 
function _getpts(plt::Makie.Lines)
  Point{2,Float32}.(plt[1][])
end 

function _get_point_groups(plots)
  pts = Point{2,Float32}[]
  groups = UnitRange{Int}[] 
  for p in plots
    if typeof(p) <: Scatter || typeof(p) <: Lines
      lstart = length(pts)+1
      push!(pts, _getpts(p)...)
      lend = length(pts)
      push!(groups, lstart:lend)
    end
  end 
  return pts, groups
end 

function _get_points_rect(pts)
  xmin,xmax = extrema(first, pts)
  ymin,ymax = extrema(last, pts)
  
  return Rectangle(Point2f(xmin,ymin),Point2f(xmax,ymax))
end 

function _find_bigcells(tess, groups)
  area = voronoiarea(tess)
  keypts = Int[] 
  for group in groups
    bigid = 0
    bigarea = 0.0 
    for i in group
      if area[i] > bigarea
        bigid = i 
        bigarea = area[i]
      end
    end 
    push!(keypts, bigid)
  end
  return keypts
end 

function _walk_connected_for_area_and_center!(i, G, tess, areas, visited)
  tovisit = Queue{Int}()
  enqueue!(tovisit, i)
  visited[i] = true 
  cellsum = sum(tess.Cells[i])
  ncells = length(tess.Cells[i])
  totalarea = areas[i]
  while length(tovisit) > 0
    v = dequeue!(tovisit)
    for n in G[v]
      if visited[n] == false
        enqueue!(tovisit, n)
        visited[n] = true
        cellsum += sum(tess.Cells[n])
        ncells += length(tess.Cells[n])
        totalarea += areas[n]
      end
    end
  end
  return totalarea, cellsum/ncells
end 

function _find_regions(pedges, points, tess, groups; nearbypoints::Int=5)
  # index the graph
  # assume that we have only one part of the undirected graph 
  n = length(points) 
  G = [ Int[] for i in 1:n ]
  rval = @NamedTuple{ref::Point2f,dir::Point2f}[] 
  for e in pedges
    push!(G[e[1]], e[2])
    push!(G[e[2]], e[1])
  end 
  # find connected regions
  visited = zeros(Bool, n)
  areas = voronoiarea(tess)
  for grp in groups
    # find the median of the areas for the group.
    bigarea = 0.0 
    bestcenter = points[first(grp)]
    for i in grp 
      if visited[i] == false
        area, center = _walk_connected_for_area_and_center!(i, G, tess, areas, visited)
        if area > bigarea
          bigarea = area
          bestcenter = center
        end
      end 
    end 
    # sort all the points by distance to bestcenter
    dists = map(i->(i,norm(points[i] - bestcenter)), grp)
    smallest = partialsort!(dists, 1:min(length(dists),2*nearbypoints);by=x->x[2])
    # find the nearest points of biggest area... 
    biggest = partialsort!(smallest, 1:min(length(smallest),nearbypoints);
      by=x->areas[x[1]], rev=true)
    # useful for debugging... 
    # map(x->poly!(f.axis, tess.Cells[x[1]], color=:grey), biggest)
    bestcenter = mean(x->mean(tess.Cells[x[1]]), biggest)
    refpt = mean(x->points[x[1]], biggest)
    #push!(rval, (ref=refpt, dir=normalize(bestcenter-refpt)))
    push!(rval, (ref=refpt, dir=(bestcenter-refpt)))
  end
  return rval
end 

function _group_for_point(pointindex, grps) # silly linear search
  for i in eachindex(grps)
    if pointindex in grps[i]
      return i 
    end
  end 
  return nothing 
end 

function _filter_edges!(edges, groups, tess; quantilelevel=0.6)
  areas = voronoiarea(tess)
  minarea_for_group = map(grp->quantile(@view(areas[grp]), quantilelevel), groups)
  return filter!(e->
    begin 
      grp1 = _group_for_point(e[1],groups)
      grp2 = _group_for_point(e[2],groups)
      return grp1 == grp2 && 
        areas[e[1]] >= minarea_for_group[grp1] &&
        areas[e[2]] >= minarea_for_group[grp1] 
    end, 
    edges)
end 



function _draw_label(ax, point, center, label, plot; offset=0.1)
  #dir = (center - points[point])
  obsoffset = Observable{Float32}(offset)
  obj = text!(ax, @lift((1-$obsoffset)*point+($obsoffset)*center), 
    text=label, color = plot.color,
    align = (:center, :center)
  )
  return (offset=obsoffset, text=obj)
end

voronoi_labels!(f::Makie.FigureAxisPlot; kwargs...) = voronoi_labels!(f.axis; kwargs...)

function voronoi_labels!(ax::Makie.Axis; offset=0.5, quantilelevel=0.6,
    pointcenter=false, nearbypoints::Int=5)
  plots,labels = Makie.get_labeled_plots(ax; merge=false, unique=false)
  points, groups = _get_point_groups(plots)
  rect = _get_points_rect(points)
  edges = Vector{Tuple{Int,Int}}()
  tess = voronoicells(points, rect; edges)
  edges = _filter_edges!(edges, groups, tess; quantilelevel) # forward quantilelevel
  rdata = _find_regions(edges, points, tess, groups; nearbypoints)

  #group_points = _find_bigcells(tess, groups)
  #centers = mean.(tess.Cells[group_points])


  #return map( zipinfo-> _draw_label(ax, zipinfo...; kwargs...),
  #  zip(rdata, centers, labels, plots) )

  rval = [] 
  for (gpoint, label, plot) in zip(rdata, labels, plots)
    # push!(rval, _draw_label(ax, points[gpoint.pointindex], 
    #   pointcenter ? gpoint.center : mean(tess.Cells[gpoint.pointindex]), 
    #   label, plot; offset))
    push!(rval, _draw_label(ax, gpoint.ref, gpoint.ref+gpoint.dir, 
      label, plot; offset)) 
  end 
  return rval
end 

function _bbox(tt::Makie.MakieCore.Text)
  refpt=tt.converted[1][][]
  gc = tt.plots[1][1][][]
  #glyphbbs = Makie.gl_bboxes(gc)
  glyphbbs = map(Makie.height_insensitive_boundingbox_with_advance, gc.extents)
  #glyphorigins = gc.origins

  
  bb = Rect2f()
  hadvance = 0.0 
  #for (charo, glyphbb) in zip(glyphorigins, glyphbbs)
  for glyphbb in glyphbbs
    #glyphbb = Rect2f(20*origin(glyphbb),20*widths(glyphbb))
    charbb = (glyphbb + Point2f(hadvance, 0.0))
    if !Makie.isfinite_rect(bb)
      bb = charbb
    else
      bb = union(bb, charbb)
    end
    hadvance += width(glyphbb)
  end 
  bb = bb + refpt
  return bb 
end 

lbls = voronoi_labels!(f;offset=0,pointcenter=false)

#@show mybb = _bbox(lbls[1])
#poly!(f.figure.scene, boundingbox(lbls[1]))
f

