struct VLAE
    e
    d
    g # extracts latent variables
    f # concatenates latent vars with the rest
    xdim # (h,w,c)
    zdim # scalar
    var # dense or conv last layer
end

Flux.@functor VLAE
(m::VLAE)(x) = reconstruct(m, x)

function VLAE(zdim::Int, ks, ncs, stride, datasize; layer_depth=1, var=:dense, activation="relu")
    nl = length(ncs) # no layers
    # this captures the dimensions after each convolution
    sout = Tuple(map(j -> datasize[1:2] .- [sum(map(k->k[i]-1, ks[1:j])) for i in 1:2], 1:length(ncs))) 
    # this is the vec. dimension after each convolution
    #ddim = map(i->prod(sout[i])*ncs[i], 1:length(ncs))
    #ddim_d = copy(ddim)
    #ddim_d[1:end-1] .= ddim_d[1:end-1]/2
    ddim = map(i->floor(Int,prod(sout[i])*ncs[i]/2), 1:length(ncs))
    ddim_d = copy(ddim)
    ddim_d[end] = ddim_d[end]*2
    indim = prod(datasize[1:3])
    rks = reverse(ks)
    rsout = reverse(sout)

    # number of channels for encoder/decoder
#    ncs_in_e = vcat([datasize[3]], [n for n in ncs[1:end-1]])
    ncs_in_e = vcat([datasize[3]], [floor(Int,n/2) for n in ncs[1:end-1]])
    ncs_in_d = reverse(ncs)
    ncs_out_d = vcat([floor(Int,n/2) for n in ncs_in_d[2:end]], [datasize[3]])
    ncs_out_f = vcat([floor(Int,n/2) for n in ncs[1:end-1]], [ncs[end]])
    
    # activation function
    af = (typeof(activation) <: Function) ? activation : eval(Meta.parse(activation))

    # encoder/decoder
    e = Tuple([Conv(ks[i], ncs_in_e[i]=>ncs[i], af, stride=stride) for i in 1:nl])
    if var == :dense
	    d = Tuple([[ConvTranspose(rks[i], ncs_in_d[i]=>ncs_out_d[i], af, stride=stride) for i in 1:nl-1]...,
	    		Chain(
	    			ConvTranspose(rks[end], ncs_in_d[end]=>ncs_out_d[end], af, stride=stride),
				    x->reshape(x, :, size(x,4)),
				    Dense(indim, indim+1)
	    		)]
	    	)
	elseif var == :conv
		ncs_out_d[end] += 1
	    d = Tuple([[ConvTranspose(rks[i], ncs_in_d[i]=>ncs_out_d[i], af, stride=stride) for i in 1:nl-1]...,
	    			ConvTranspose(rks[end], ncs_in_d[end]=>ncs_out_d[end], stride=stride)]
	    		)
	else
		error("Decoder var=$var not implemented! Try one of `[:dense, :conv]`.")
	end    
    
    # latent extractor
    g = Tuple([Chain(x->reshape(x, :, size(x,4)), Dense(ddim[i], zdim*2)) for i in 1:nl])
    
    # latent reshaper
    f = Tuple([Chain(Dense(zdim, ddim_d[i], af), 
            x->reshape(x, sout[i]..., ncs_out_f[i], size(x,2))) for i in nl:-1:1])

    return VLAE(e,d,g,f,datasize[1:3],zdim,var)
end

# improved elbo
function elbo(m::VLAE, x::AbstractArray{T,4}) where T
    # encoder pass
    μzs_σzs = _encoded_mu_vars(m, x)
    zs = map(y->rptrick(y...), μzs_σzs)
    kldl = sum(map(y->Flux.mean(kld(y...)), μzs_σzs))
        
    # decoder pass
    μx, σx = _decoded_mu_var(m, zs...)
    _x = (m.var == :dense) ? vectorize(x) : x
        
    -kldl + Flux.mean(logpdf(_x, μx, σx))
end

function _encoded_mu_vars(m::VLAE, x)
    nl = length(m.e)

    h = x
    mu_vars = map(1:nl) do i
        h = m.e[i](h)
        nch = floor(Int,size(h,3)/2)
        μz, σz = mu_var(m.g[i](h[:,:,(nch+1):end,:]))
        h = h[:,:,1:nch,:]
        (μz, σz)
    end
    mu_vars
end

function _decoded_mu_var(m::VLAE, zs...)
    nl = length(m.d)
    @assert length(zs) == nl
    
    h = m.f[1](zs[end])
    # now, propagate through the decoder
    for i in 1:nl-1
        h1 = m.d[i](h)
        h2 = m.f[i+1](zs[end-i])
        h = cat(h1, h2, dims=3)
    end
    h = m.d[end](h)
    μx, σx = mu_var1(h)
end

function train_vlae(zdim, batchsize, ks, ncs, stride, nepochs, data, val_x, tst_x; 
    λ=0.0f0, epochsize = size(data,4), layer_depth=1, lr=0.001f0, var=:dense, activation=activation)
    gval_x = gpu(val_x[:,:,:,1:min(1000, size(val_x,4))])
    gtst_x = gpu(tst_x)
    
    model = gpu(VLAE(zdim, ks, ncs, stride, size(data), layer_depth=layer_depth, var=var, 
        activation=activation))
    nl = length(model.e)
    
    ps = Flux.params(model)
    loss(x) = -elbo(model,gpu(x)) + λ*sum(l2, ps)
    opt = ADAM(lr)
    rdata = []
    hist = []
    zs = [[] for _ in 1:nl]
    
    # train
    println("Training in progress...")
    for epoch in 1:nepochs
        data_itr = Flux.Data.DataLoader(data[:,:,:,sample(1:size(data,4), epochsize)], batchsize=batchsize)
        Flux.train!(loss, ps, data_itr, opt)
        l = Flux.mean(map(x->loss(x), Flux.Data.DataLoader(val_x, batchsize=batchsize)))
        println("Epoch $(epoch)/$(nepochs), validation loss = $l")
        for i in 1:nl
            z = encode(model, gval_x, i)
            push!(zs[i], cpu(z))
        end
        push!(hist, l)
        push!(rdata, cpu(reconstruct(model, gval_x)))
    end
    
    return model, hist, rdata, zs
end

function encode(m::VLAE, x, i::Int)
    μzs_σzs = _encoded_mu_vars(m, x)
    rptrick(μzs_σzs[i]...)
end
encode(m::VLAE, x) = encode(m, x, length(m.g))
encode_all(m::VLAE, x) = map(y->rptrick(y...), _encoded_mu_vars(m, x))
function encode_all(m::VLAE, x, batchsize::Int)
    encs = map(y->cpu(encode_all(gpu(m), gpu(y))), Flux.Data.DataLoader(x, batchsize=batchsize))
    [cat([y[i] for y in encs]..., dims=2) for i in 1:length(encs[1])]
end

function decode(m::VLAE, zs...) 
    μx, σx = _decoded_mu_var(m, zs...)
    devectorize(rptrick(μx, σx), m.xdim...)
end

reconstruct(m::VLAE, x) = decode(m, encode_all(m, x)...)

function reconstruction_probability(m::VLAE, x)  
    x = gpu(x)
    zs = map(y->rptrick(y...), _encoded_mu_vars(m, x))
    μx, σx = _decoded_mu_var(m, zs...)
    _x = (m.var == :dense) ? vectorize(x) : x
    -logpdf(_x, μx, σx)
end
reconstruction_probability(m::VLAE, x, L::Int) = mean([reconstruction_probability(m,x) for _ in 1:L])
function reconstruction_probability(m::VLAE, x, L::Int, batchsize::Int)
    vcat(map(b->cpu(reconstruction_probability(m, b, L)), Flux.Data.DataLoader(x, batchsize=batchsize))...)
end
