nProj = size(uproj,2);

uBase = zeros(1e4, nProj);
nS = zeros(1e4, 1);
ncurr = 1;

for ibatch = 1:numel(indBatch)
    % merge in with existing templates
    uS = uproj(indBatch{ibatch}, :);
    [nSnew, iNonMatch] = merge_spikes0(uBase(1:ncurr,:), nS(1:ncurr), uS, ops.crit);
    nS(1:ncurr) = nSnew;
    %
    % reduce non-matches
    [uNew, nSadd] = reduce_clusters0(uS(iNonMatch,:), ops.crit);
    
    % add new spikes to list
    uBase(ncurr + [1:size(uNew,1)], :) = uNew;
    nS(ncurr + [1:size(uNew,1)]) = nSadd;
    
    ncurr = ncurr + size(uNew,1);
    
    if ncurr>1e4
        break;
    end
end
%
nS = nS(1:ncurr);
uBase = uBase(1:ncurr, :);

[~, itsort] = sort(nS, 'descend');
 
%% initialize U
% compute covariance matrix
sigDrift = 15;
sigShift = 20;
chanDists= bsxfun(@minus, rez.yc, rez.yc').^2 + bsxfun(@minus, rez.xc, rez.xc').^2;
iCovChans = my_inv(exp(-chanDists/(2*sigDrift^2)), 1e-6);

Nfilt = ops.Nfilt;
lam = ops.lam(1) * ones(Nfilt, 1, 'single');
lam = repmat(lam, 3, 1);

U = gpuArray(uBase(itsort(1:Nfilt), :))';
mu = sum(U.^2,1)'.^.5;
U = normc(U);
%
[uniqy, ~, iqy] = unique(rez.yc);

niter = 10;
deltay = zeros(numel(uniqy), numel(indBatch), niter);
totdY  = zeros(numel(uniqy), numel(indBatch));
 
alldy = zeros(numel(uniqy), numel(indBatch));
allNSpikes = zeros(numel(uniqy), numel(indBatch));

cmap = colormap('jet');
cmap = cmap(round(linspace(1, 64, numel(uniqy))), :);

tic
%
for i = 1:niter
    % resample spatial masks up and down
    [Uup, Udown] = get_Uupdown(U, sigShift, ops, rez, iCovChans, sigDrift);
        
    mu = repmat(mu, 3, 1);
    
    dWU = zeros(Nfilt, nProj, 'single');
    nToT = gpuArray.zeros(Nfilt, 1, 'single');
    Cost = gpuArray(single(0));
    %
   
    for ibatch = 1:numel(indBatch)
        % find clusters
        clips = gpuArray(uproj(indBatch{ibatch}, :))';
        nSpikes = size(clips,2);
        clips = reshape(clips, ops.Nchan, size(clips,1)/ops.Nchan, []);
        
        if i==1
           % compute spike locations
           [~, imax]       = max(sq(sum(clips.^2,2)), [], 1); 
           ySp             = iqy(imax);
           spikeYs{ibatch} = ySp;
        else
           ySp             = spikeYs{ibatch};
        end
        clips = reshape(clips, ops.Nchan, []);
        
        % resample clips by the delta y
        clips = shift_data(clips, totdY(iqy, ibatch), rez.yc, rez.xc, iCovChans, sigDrift, rez.Wrot);        
        clips = reshape(clips, size(U,1), [])';
        
        ci = clips * [Udown U Uup];
        
        ci = bsxfun(@plus, ci, (mu .* lam)');
        cf = bsxfun(@rdivide, ci.^2, 1 + lam');
        cf = bsxfun(@minus, cf, (mu.^2.*lam)');
        
        cf           = reshape(cf,[], Nfilt, 3);
        [Mmax, imax] = max(cf, [], 2);
        [~, i3max]   = max(Mmax, [], 3);
    
        % determine added correction to delta y
        dySpikes = get_dySpikes(sq(Mmax)) * sigShift;
        
        % store this correction in a meaningful way
        [alldy(:,ibatch), allNSpikes(:,ibatch)] = bin_corrections(gather(dySpikes), ySp, numel(uniqy));        
    end
    
    % smooth out corrections
    nSmoothSpikes = my_conv2(allNSpikes, [5 5], [1 2]);
    deltay(:,:,i) = my_conv2(alldy, [5 5], [1 2])./nSmoothSpikes; 
    totdY = sum(deltay(:,:,1:i), 3);
    totdY = bsxfun(@minus, totdY, mean(totdY, 2)); 

    for j = 1:size(totdY,1)
        plot(totdY(j, :), 'Color', cmap(j,:))
        hold all
    end
    hold off
    drawnow
    %
    for ibatch = 1:numel(indBatch)
        % shift clips by the new correction
        clips   = gpuArray(uproj(indBatch{ibatch}, :))';
        nSpikes = size(clips,2);
        clips   = reshape(clips, ops.Nchan, []);
        clips   = shift_data(clips, totdY(iqy, ibatch), rez.yc, rez.xc, iCovChans, sigDrift, rez.Wrot);        
        clips   = reshape(clips, size(U,1), [])';
        %
        ci = clips * U;
        
        ci = bsxfun(@plus, ci, (mu(1:end/3) .* lam(1:end/3))');
        cf = bsxfun(@rdivide, ci.^2, 1 + lam(1:end/3)');
        cf = bsxfun(@minus, cf, (mu(1:end/3).^2.*lam(1:end/3))');
        
        cf           = reshape(cf,[], Nfilt);
        % determine cluster assignment for this iteration
        [max_cf, id] = max(cf, [], 2);
        id = gather(id);
        L = gpuArray.zeros(Nfilt, nSpikes, 'single');
        L(id' + [0:Nfilt:(Nfilt*nSpikes-1)]) = 1;
        dWU = dWU + L * clips;
        nToT = nToT + sum(L, 2);
        Cost = Cost + mean(max_cf);
    end
    dWU  = bsxfun(@rdivide, dWU, nToT);
    
    U = dWU';
    mu = sum(U.^2,1)'.^.5;
    U = normc(U);
    Cost = Cost/numel(indBatch);
    
    
    [toc Cost std(totdY(:))]
    
    %     plot(sort(log(1+nToT)))
    %     drawnow
end
%%
Nchan = ops.Nchan;
Nfilt = ops.Nfilt;
wPCA = ops.wPCA(:,1:3);
Urec = reshape(U, Nchan, size(wPCA,2), Nfilt);

nt0 = 61;
Urec= permute(Urec, [2 1 3]);
Wrec = reshape(wPCA * Urec(:,:), nt0, Nchan, Nfilt);

Wrec = gather(Wrec);
Nrank = 3;
W = zeros(nt0, Nfilt, Nrank, 'single');
U = zeros(Nchan, Nfilt, Nrank, 'single');
for j = 1:Nfilt
    [w sv u] = svd(Wrec(:,:,j));
    w = w * sv;
    
    Sv = diag(sv);
    W(:,j,:) = w(:, 1:Nrank)/sum(Sv(1:ops.Nrank).^2).^.5;
    U(:,j,:) = u(:, 1:Nrank);
end

Uinit = U;
Winit = W;
mu = gather(single(mu));
muinit = mu;

WUinit = zeros(nt0, Nchan, Nfilt);
for j = 1:Nfilt
    WUinit(:,:,j) = muinit(j)  * Wrec(:,:,j);
end
WUinit = single(WUinit);
%%


