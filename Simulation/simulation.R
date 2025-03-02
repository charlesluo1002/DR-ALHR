Cox_AIPCW <- function(data, beta0 = 0, threshold = 1e-8, max_iter = 100,T_AZ = 'Spline', C_AZ = 'RSF', min.S = 1e-2, remove.last = T, tau = 1, k = 5){
  # inputs:
  # data: nx(3 + p) matrix, first 3 columns (X, Delta, A) are fixed, the rest are baseline covariates Z
  #   X - nx1, the censored event time for each patient
  #   Delta - nx1, the event indicator for each patient, 1 = Died, 0 = Censored.
  #   A - nx1, 0/1 treatment variable
  #   Z - nxp, the baseline covariates matrix
  # beta0 - initial value for beta
  # threshold - convergence threshold for the difference in beta
  # max_iter - maximum iterations of Newton-Raphson allowed.
  # T_AZ - working model for the T|A,Z, available ones include ('Cox', 'Spline', 'RSF', 'llogis')
  # C_AZ - working model for the C|A,Z, available ones include ('Cox', 'Spline', 'RSF', 'llogis')
  # k - number of folds for cross fitting
  
  # Estimate S and S_c using k-fold cross-fitting
  data = as.data.frame(data)#[sample(nrow(data)),]
  colnames(data)[1:3] = c('X','Delta','A')
  colnames(data)[-(1:3)] = paste0('Z',1:(ncol(data) - 3))
  X.full = data[,1]
  X.sort.full = sort(unique(X.full))
  folds = cut(1:nrow(data), breaks = k, labels = F)
  S_t.temp = S_c.temp = matrix(0, nrow = nrow(data), ncol = length(unique(X.full)))
  # sample split functions
  samp.split_S_t = function(dfs, dfn, dfn.c,n,X,n_res,Delta,Delta_c,A,Z,p,X.sort, X.full,X.sort.full){
    S_t = data.frame(matrix(0, nrow = nrow(dfs), ncol = length(unique(X.full))))
    if (T_AZ == 'fail1'){
      f = as.formula(paste0('Surv(X, Delta)~',paste(colnames(dfn)[-(1:3)], collapse = '+')))
      model0 = flexsurvreg(f , dist ='llogis', data = dfn[dfn$A==0,])
      model1 = flexsurvreg(f , dist ='llogis', data = dfn[dfn$A==1,])
      pred0 = predict(model0, newdata = dfs[dfs$A==0,], type = 'survival', times = X.sort.full)$.pred
      pred1 = predict(model1, newdata = dfs[dfs$A==1,], type = 'survival', times = X.sort.full)$.pred
      S_t[dfs$A==0,] = t(sapply(pred0, function(x) x$.pred))
      S_t[dfs$A==1,] = t(sapply(pred1, function(x) x$.pred))
    }
    if (T_AZ == 'Cox'){
      model = coxph(Surv(X, Delta) ~ ., timefix = F, data = dfn)
      Lambda = exp(as.matrix(dfs[,-(1:2)])%*%model$coefficients) %*% t(basehaz(model, centered = F)$hazard)
      S_t[,X.sort.full %in% X.sort] = exp(-Lambda)
    }
    if (T_AZ == 'Spline'){
      model = hare(X, Delta, cbind(A,Z))
      S_t = 1 - sapply(X.sort.full, function(x) phare(q = x, cov = dfs[,-(1:2)], fit = model))
      S_t[is.nan(S_t)] = NA
    }
    if (T_AZ == 'RSF'){
      model = rfsrc(Surv(X, Delta) ~ ., data = dfn, ntree = 1000, ntime = 0, mtry = 2, splitrule = 'bs.gradient')
      S_t[, which(X.sort.full %in% model$time.interest)] = predict(model, newdata = dfs)$survival
    }
    S_t[,1] = ifelse(S_t[,1] == 0 | is.na(S_t[,1]), 1, S_t[,1])
    S_t[S_t==0] = NA
    S_t = t(as.matrix(tidyr::fill(data.frame(t(S_t)), names(data.frame(t(S_t))))))
    return(S_t)
  }
  
  samp.split_S_c = function(dfs, dfn, dfn.c,n,X,n_res,Delta,Delta_c,A,Z,p,X.sort, X.full,X.sort.full){
    S_c = data.frame(matrix(0, nrow = nrow(dfs), ncol = length(unique(X.full))))
    if (C_AZ == 'cens1'){
      model = coxph(Surv(X, Delta_c) ~ ., timefix = F, data = dfn.c[,-3])
      Lambda_c = exp(as.matrix(dfs[,-(1:3)])%*%model$coefficients) %*% t(basehaz(model, centered = F)$hazard)
      S_c[,X.sort.full %in% X.sort] = exp(-Lambda_c)
    }
    if (C_AZ == 'Cox'){
      model = coxph(Surv(X, Delta_c) ~ ., timefix = F, data = dfn.c)
      Lambda_c = exp(as.matrix(dfs[,-(1:2)])%*%model$coefficients) %*% t(basehaz(model, centered = F)$hazard)
      S_c[,X.sort.full %in% X.sort] = exp(-Lambda_c)
    }
    if (C_AZ == 'Spline'){
      model = hare(X, Delta_c, cbind(A,Z))
      S_c = 1 - sapply(X.sort.full, function(x) phare(q = x, cov = dfs[,-(1:2)], fit = model))
      S_c[is.nan(S_c)] = NA
    }
    if (C_AZ == 'RSF'){
      model = rfsrc(Surv(X, Delta_c) ~ ., data = dfn.c, ntree = 1000, ntime = 0, mtry = 2, splitrule = 'bs.gradient')
      S_c[, which(X.sort.full %in% model$time.interest)] = predict(model, newdata = dfs[,-(1:2)])$survival
    }
    S_c[,1] = ifelse(S_c[,1] == 0 | is.na(S_c[,1]), 1, S_c[,1])
    S_c[S_c==0] = NA
    S_c = t(as.matrix(tidyr::fill(data.frame(t(S_c)), names(data.frame(t(S_c))))))
    return(S_c)
  }
  # cross fitting
  for (fold in 1:k){
    dfs = data[folds==fold,]
    dfn = dfn.c = data[folds!=fold,]
    n = nrow(dfn)
    X = dfn[,1]
    n_res = length(unique(X))
    Delta = dfn[,2]
    Delta_c = (1 - Delta)*(X < tau)
    dfn.c$Delta = Delta_c
    colnames(dfn.c)[2] = 'Delta_c'
    A = dfn[,3]
    Z = as.matrix(dfn[,-(1:3)])
    p = ncol(Z)
    X.sort = sort(unique(X))
    S_t.temp[folds==fold,] = samp.split_S_t(dfs, dfn, dfn.c,n,X,n_res,Delta,Delta_c,A,Z,p,X.sort, X.full,X.sort.full)
    S_c.temp[folds==fold,] = samp.split_S_c(dfs, dfn, dfn.c,n,X,n_res,Delta,Delta_c,A,Z,p,X.sort, X.full,X.sort.full)
  }
  S_t = as.matrix(S_t.temp)
  S_c = as.matrix(S_c.temp)
  
  # define all parameters and covariates
  n = nrow(data)
  X = data[,1]
  n_res = length(unique(X))
  Delta = data[,2]
  Delta_c = (1 - Delta)*(X < tau)
  A = data[,3]
  Z = as.matrix(data[,-(1:3)])
  p = ncol(Z)
  X.sort = sort(unique(X))
  event_rank = pmin(n_res,rank(X, ties.method = 'first'))
  Y = t(sapply(event_rank, function(x) c(rep(1,x), rep(0,n_res-x))))   # n x n_res  (sample x time)
  dNt = t(sapply(event_rank, function(x) tabulate(x, nbins = n_res))) * Delta    # n x n_res  (sample x time)
  
  
  # beta estimation with weight trimming
  check = T
  calc_min.S = function(x) tanh(x)/2+0.5
  min.S.base = atanh((min.S - 0.5)*2)
  # while B2_0 is negative, increase min.S
  while (check){
    min.S.base = min.S.base + 0.25
    min.S = calc_min.S(min.S.base)
    if (min(S_t) < min.S) S_t = 1 - (1 - S_t)*(1 - min.S)/(1-min(S_t))
    if (min(S_c) < min.S) S_c = 1 - (1 - S_c)*(1 - min.S)/(1-min(S_c))
    Lambda_c = -log(S_c) # n x n_res  (sample x time)
    lambda_c = t(apply(Lambda_c, 1, function(x) c(x[1], diff(x))))    # n x n_res  (sample x time)
    # calculate J
    dNc = t(sapply(event_rank, function(x) tabulate(x, nbins = n_res))) * Delta_c # n x n_res  (sample x time)
    dMc = dNc - Y * lambda_c   # n x n_res  (sample x time)
    J = t(apply(dMc/S_t/S_c, 1, cumsum))   # n x n_res  (sample x time)
    dF_t = t(apply(1-S_t, 1, function(x) c(x[1], diff(x))))   # n x n_res  (sample x time)
    dB1 = (dNt/S_c + J*dF_t)  # n x n_res  (sample x time)
    if (remove.last) dB1 = dB1[,-n_res]
    
    # function for calculating B2_l
    calc_B2 = function(beta, l = 0)  colMeans(A^l*exp(beta*A) * (Y/S_c + J*S_t)) # n_res x 1   (time x 1)
    if (remove.last) calc_B2 = function(beta, l = 0)  colMeans(A^l*exp(beta*A) * (Y/S_c + J*S_t))[-n_res]
    calc_A_bar = function(beta)  (calc_B2(beta,1)/calc_B2(beta,0)) # n_res x 1   (time x 1)
    calc_U = function(A_bar)  sum((dB1*outer(A, A_bar, '-')))/n   #  1x1
    calc_dU = function(A_bar)  - sum((t(dB1)*(A_bar - A_bar^2)))/n   #  1x1
    calc_PL = function(beta) sum((dB1*outer(A*beta, log(abs(calc_B2(beta,0))), '-')))/n   #  1x1
    calc_beta = function(beta0){
      beta = beta0
      diff = 999
      iter_count = 0
      while(diff > threshold){
        beta_old = beta
        A_bar = calc_A_bar(beta)
        U = calc_U(A_bar)
        dU = calc_dU(A_bar)
        beta = beta - U/dU
        diff = abs(beta - beta_old)
        iter_count = iter_count + 1
        if (iter_count > max_iter) stop(paste('Did not converge after',max_iter,'steps.'))
      }
      return(beta)
    }
    
    B2.min = min(min(calc_B2(-10)), min(calc_B2(10)))
    U_sign = calc_U(calc_A_bar(-10))*calc_U(calc_A_bar(10))
    not.converged = F
    tryCatch({beta = calc_beta(beta0)},
             error = function(e) not.converged <<- T)
    check = (B2.min < 1e-4 | is.nan(B2.min) | U_sign >= 0 | not.converged)
    min.S = calc_min.S(min.S.base)
  }
  
  # points = seq(-10,10,length.out = 100)
  # plot(points, sapply(points, function(x) calc_PL(x)))
  # plot(points, sapply(points, function(x) calc_U(calc_A_bar(x))))
  # plot(points, sapply(points, function(x) calc_dU(calc_A_bar(x))))
  # plot(points, sapply(points, function(x) min(calc_B2(x))))
  
  # model se
  A_bar = calc_A_bar(beta)
  K = mean(rowSums((dB1   -   t(t(exp(beta*A) * (Y/S_c + J*S_t))[-n_res,]/calc_B2(beta)*colMeans(dB1)))*outer(A, A_bar, '-'))^2)
  nu = mean(colSums(t(dB1)*(A_bar - A_bar^2)))
  model_se = sqrt(K/nu^2/n)
  return(list(beta = beta, model_se = model_se, min.S = min.S))
}



Cox_IPCW <- function(data, beta0 = 0, threshold = 1e-6, max_iter = 100, C_AZ = 'Cox', remove.last = T, min.S = 1e-2, tau = 1){
  # inputs:
  # data: nx(p+3) matrix, first 3 columns (X, Delta, A) are fixed, the rest are baseline covariates Z
  #   X - nx1, the censored event time for each patient
  #   Delta - nx1, the event indicator for each patient, 1 = Died, 0 = Censored.
  #   A - nx1, 0/1 treatment variable
  #   Z - nxp, the baseline covariates matrix
  # beta0 - initial value for beta
  # threshold - convergence threshold for the difference in beta
  # max_iter - maximum iterations of Newton-Raphson allowed.
  # C_AZ - working model for C|AZ,  'exp-AZ' or 'exp-A' or 'exp'
  n = nrow(data)
  X = data[,1]
  n_res = length(unique(X))
  Delta = data[,2]
  Delta_c = (1 - Delta)*(X<tau)
  A = data[,3]
  Z = as.matrix(data[,-(1:3)])
  p = ncol(Z)
  X.sort = sort(unique(X))
  event_rank = pmin(n_res,rank(X, ties.method = 'first'))
  model_se = 0
  Y = t(sapply(event_rank, function(x) c(rep(1,x), rep(0,n_res-x))))   # n x n_res  (sample x time)
  dNt = t(sapply(event_rank, function(x) tabulate(x, nbins = n_res))) * Delta    # n x n_res  (sample x time) 
  if (C_AZ == 'cens1'){
    model = coxph(Surv(X, Delta_c) ~ Z, timefix = F)
    Lambda_c = exp(Z%*%model$coefficients) %*% t(basehaz(model, centered = F)$hazard)
    S_c = exp(-Lambda_c)
    S_c[,1] = ifelse(S_c[,1] == 0, 1, S_c[,1])
    S_c[S_c==0] = NA
    S_c = t(as.matrix(tidyr::fill(data.frame(t(S_c)), names(data.frame(t(S_c))))))
  }
  if (C_AZ == 'Spline'){
    model = hare(X, Delta_c, cbind(A,Z))
    S_c = 1 - sapply(sort(unique(X)), function(x) phare(q = x, cov = cbind(A,Z), fit = model))
    S_c[is.nan(S_c)] = NA
    S_c[,1] = ifelse(S_c[,1] == 0 | is.na(S_c[,1]), 1, S_c[,1])
    if(any(is.na(S_c))) S_c = t(as.matrix(tidyr::fill(data.frame(t(S_c)), names(data.frame(t(S_c))))))
  }
  if (C_AZ == 'RSF'){
    dat = data.frame(cbind(X,Delta_c,A,Z))
    colnames(dat) = c('X','Delta_c','A',paste0('Z',1:p))
    model = rfsrc(Surv(X, Delta_c) ~ ., data = dat, ntree = 1000, ntime = X.sort, mtry = 2, splitrule = 'bs.gradient')
    S_c = matrix(0, nrow = n, ncol = n_res)
    S_c[, which(X.sort %in% model$time.interest)] = model$survival.oob
    S_c[,1] = ifelse(S_c[,1] == 0, 1, S_c[,1])
    S_c[S_c==0] = NA
    if(any(is.na(S_c))) S_c = t(as.matrix(tidyr::fill(data.frame(t(S_c)), names(data.frame(t(S_c))))))
  }
  if (C_AZ == 'Cox'){
    model = coxph(Surv(X, Delta_c) ~ A + Z, timefix = F)
    Lambda_c = exp(cbind(A,Z)%*%model$coefficients) %*% t(basehaz(model, centered = F)$hazard)
    S_c = exp(-Lambda_c)
    S_c[,1] = ifelse(S_c[,1] == 0, 1, S_c[,1])
    S_c[S_c==0] = NA
    S_c = t(as.matrix(tidyr::fill(data.frame(t(S_c)), names(data.frame(t(S_c))))))
  }
  if (C_AZ == 'A'){
    S_c = data.frame(matrix(0, nrow = n_res, ncol = n))
    model0 = survfit(Surv(X[A==0], Delta_c[A==0])~1, timefix = F)
    model1 = survfit(Surv(X[A==1], Delta_c[A==1])~1, timefix = F)
    X.sort = sort(unique(X))
    S_c[which(X.sort %in% model0$time), A==0] = cbind(exp(-model0$cumhaz))[,rep(1,sum(A==0))]
    S_c[which(X.sort %in% model1$time), A==1] = cbind(exp(-model1$cumhaz))[,rep(1,sum(A==1))]
    S_c[1,] = ifelse(S_c[1,] == 0, 1, S_c[1,])
    S_c[S_c==0] = NA
    S_c = t(as.matrix(tidyr::fill(S_c, names(S_c))))
  }
  if (C_AZ == '1'){
    model = survfit(Surv(X, Delta) ~ 1, timefix = F)
    S_t = model$surv
    S_t[S_t == 0] = min(S_t[S_t>0])
    S_c = matrix(replicate(n, colSums(Y)/S_t), nrow = n, byrow = T)/n
  }
  S_c = as.matrix(S_c)
  if (min(S_c) < min.S) S_c = 1 - (1 - S_c)*(1 - min.S)/(1-min(S_c))
  dB1 = dNt/S_c; if (remove.last) dB1 = dB1[,-n_res] # n x n_res  (sample x time) 
  # function for calculating B2_l
  calc_B2 = function(beta, l = 0)  colMeans(A^l*exp(beta*A) *  Y/S_c)  # n_res x 1   (time x 1) 
  if (remove.last)  calc_B2 = function(beta, l = 0)  colMeans(A^l*exp(beta*A) *  Y/S_c)[-n_res]
  calc_A_bar = function(beta)  calc_B2(beta,1)/calc_B2(beta,0) # n_res x 1   (time x 1)   
  calc_U = function(A_bar)  sum(dB1*outer(A, A_bar, '-'))/n   #  1x1         
  calc_dU = function(A_bar)  - sum(t(dB1)*(A_bar - A_bar^2))/n   #  1x1      
  calc_PL = function(beta)  sum((dB1*outer(A*beta, log(calc_B2(beta,0)), '-')))/n   #  1x1 
  calc_beta = function(beta0){
    beta = beta0
    diff = 999
    iter_count = 0
    while(diff > threshold){
      beta_old = beta
      A_bar = calc_A_bar(beta)
      U = calc_U(A_bar)
      dU = calc_dU(A_bar)
      beta = beta - U/dU
      diff = abs(beta - beta_old)
      iter_count = iter_count + 1
      if (iter_count > max_iter) stop(paste('Did not converge after',max_iter,'steps.'))
    }  # 16.48s per 100 runs
    return(beta)
  }
  
  # calculate beta
  beta = calc_beta(beta0)
  # model se using robust estimator sqrt(|U.star|_2^2 / dU^2)
  A_bar = calc_A_bar(beta)
  B2.0 = calc_B2(beta)
  B2.1 = calc_B2(beta, l=1)
  dU = calc_dU(A_bar)
  T.Y_S_c = t(Y/S_c)
  if (remove.last) T.Y_S_c = T.Y_S_c[-n_res,]
  U.star = (rowSums(dB1*outer(A, A_bar, '-')) - A*exp(beta*A)*colSums(T.Y_S_c/B2.0) + exp(beta*A)*colSums(T.Y_S_c*B2.1/B2.0^2))/n
  model_se = sqrt(sum(U.star^2)/n/dU^2 / n)
  return(list(beta = beta, model_se = model_se, min.S = min.S))
}


simulate <- function(Scenario = 1, beta_true = -1, n = 1000){
  n_original = n
  n = ceiling(n*1.01)
  A = rbinom(n, 1, 0.5)
  
  if (Scenario == 1){
    eps = runif(n,-1,1)
    Z1 = 0.5*eps + rnorm(n,0, sd = 1) # max is 0.5 + 4 = 4.5
    Z2 = eps^2 + rnorm(n,0, sd = 0.3) # max is 1+0.3*4 = 2.2
    Z = cbind(Z1,Z2)
    t = -log(0.5*eps+0.5)*exp(-beta_true*A)
    c = -log(runif(n))/exp(-1 + as.vector(Z%*%c(0, 2)))
  }
  if (Scenario == 2){
    eps = runif(n,-1,1)
    Z1 = 0.5*eps + rnorm(n,0, sd = 1)
    Z2 = eps^2 + rnorm(n,0, sd = 0.3) 
    Z = cbind(Z1,Z2)
    t = -log(0.5*eps+0.5)*exp(-beta_true*A)
    c = rep(0,n)
    c[Z1>0] = exp(0 - 0.2*A[Z1>0] + as.vector(sqrt(abs(Z[Z1>0,]))%*%c(0, -2)) + 0.3*rlnorm(sum(Z[,1]>0)))
    c[Z1<=0] = exp(2.4 - 0.3*A[Z1<=0] + as.vector(sqrt(abs(Z[Z1<=0,]))%*%c(0.5, 0.5)) - 1*rlnorm(sum(Z[,1]<=0)))

  X = pmin(t,c)
  Delta = 1*(t<c)
  duplicated_index = unique(c(which(duplicated(X)), which(duplicated(t)), which(duplicated(c))))
  if (length(duplicated_index) != 0) {
    cat(paste(length(duplicated_index) ,'duplicates detected.\n'))
    return(cbind(t, c, X, Delta, A, Z)[-duplicated_index,][1:n_original,])
  }else return(cbind(t, c, X, Delta, A, Z)[1:n_original,])
}


one_setting_simulation = function(n_sim = 1000, tau = 1, Scenario = 1, beta_true = -1, id = 1){
  set.seed(id)
  data = simulate(n = n_sim, Scenario = Scenario, beta_true = beta_true)[,-(1:2)]
  data[,2] = data[,2]*(data[,1] < tau)
  data[,1] = ifelse(data[,1] < tau, data[,1], tau)
  
  estimators = c('AIPCW-Cox-Cox', 'AIPCW-Cox-spline', 'AIPCW-Cox-rsf', 'AIPCW-spline-Cox', 'AIPCW-rsf-Cox', 'AIPCW-spline-spline', 'AIPCW-rsf-rsf', 'IPCW-Cox', 'IPCW-spline','IPCW-rsf', 'IPCW-A', 'IPCW-1', 'MPLE')
  beta_est = model_se = min_S_list = rep(0, length(estimators))
  # beta0 = beta_true;  T_AZ = 'fail1'; C_AZ = 'cens1';threshold = 1e-8; max_iter = 100; remove.last = T; min.S = 0.007; tau = tau
  if (IPCW_only == T){
    res8 = Cox_IPCW(data = data, C_AZ = 'Cox' , beta0 = beta_true,tau = tau)
    res9 = Cox_IPCW(data = data, C_AZ = 'Spline' , beta0 = beta_true,tau = tau)
    res10 = Cox_IPCW(data = data, C_AZ = 'RSF' , beta0 = beta_true,tau = tau)
    res11 = Cox_IPCW(data = data, C_AZ = 'A' , beta0 = beta_true,tau = tau)
    res12 = Cox_IPCW(data = data, C_AZ = '1' , beta0 = beta_true,tau = tau)
    cox.model = coxph(Surv(data[,1], data[,2])~data[,3], timefix = F)
    beta_est[13] = as.numeric(cox.model$coefficient)
    model_se[13] = as.numeric(summary(cox.model)$coefficients[3])
    for (i in 8:(length(estimators) - 1)){
      eval(parse(text = paste0('beta_est[',i,'] = res',i,'$beta')))
      eval(parse(text = paste0('model_se[',i,'] = res',i,'$model_se')))
      eval(parse(text = paste0('min_S_list[',i,'] = res',i,'$min.S')))
    }
  }else{
    res1 = Cox_AIPCW(data = data, T_AZ = 'Cox', C_AZ = 'Cox', beta0 = beta_true,tau = tau)
    res2 = Cox_AIPCW(data = data, T_AZ = 'Cox',C_AZ = 'Spline', beta0 = beta_true,tau = tau)
    res3 = Cox_AIPCW(data = data, T_AZ = 'Cox', C_AZ = 'RSF',beta0 = beta_true,tau = tau)
    res4 = Cox_AIPCW(data = data, T_AZ = 'Spline',C_AZ = 'Cox',beta0 = beta_true,tau = tau)
    res5 = Cox_AIPCW(data = data, T_AZ = 'RSF',   C_AZ = 'Cox', beta0 = beta_true,tau = tau)
    res6 = Cox_AIPCW(data = data, T_AZ = 'Spline', C_AZ = 'Spline', beta0 = beta_true,tau = tau)
    res7 = Cox_AIPCW(data = data, T_AZ = 'RSF',   C_AZ = 'RSF', beta0 = beta_true,tau = tau)
    res8 = Cox_IPCW(data = data,  C_AZ = 'Cox' ,beta0 = beta_true,tau = tau)
    res9 = Cox_IPCW(data = data,  C_AZ = 'Spline',beta0 = beta_true,tau = tau)
    res10 = Cox_IPCW(data = data, C_AZ = 'RSF' ,  beta0 = beta_true,tau = tau)
    res11 = Cox_IPCW(data = data, C_AZ = 'A' ,   beta0 = beta_true,tau = tau)
    res12 = Cox_IPCW(data = data, C_AZ = '1' ,   beta0 = beta_true,tau = tau)
    cox.model = coxph(Surv(data[,1], data[,2])~data[,3], timefix = F)
    beta_est[13] = as.numeric(cox.model$coefficient)
    model_se[13] = as.numeric(summary(cox.model)$coefficients[3])
    for (i in 1:(length(estimators) - 1)){
      eval(parse(text = paste0('beta_est[',i,'] = res',i,'$beta')))
      eval(parse(text = paste0('model_se[',i,'] = res',i,'$model_se')))
      eval(parse(text = paste0('min_S_list[',i,'] = res',i,'$min.S')))
    }
  }
  # calculate CP using model_se
  model.ci.low = beta_est - model_se*qnorm(0.975)
  model.ci.high = beta_est + model_se*qnorm(0.975)
  model.coverred = (model.ci.low < beta_true)*(model.ci.high > beta_true)
  res = c(beta_true, beta_est,model_se, model.coverred, min_S_list)
  names(res) = c('beta_true', rep(estimators,4))
  return(res)
}

############
library(survival)
library(parallel)
library(randomForestSRC)
library(polspline)
library(flexsurv)
library(actuar)
library(tictoc)

IPCW_only = F
n0 = 500
tau0 = 1
beta_true0 = -1
tic()
tryCatch({Script_ID = as.numeric(commandArgs(trailingOnly=TRUE))})
if (!exists('Script_ID') | length(Script_ID) == 0) Script_ID = 1
results1 = one_setting_simulation(n_sim = n0, tau = tau0, Scenario = 1, beta_true = beta_true0, id = Script_ID)
results2 = one_setting_simulation(n_sim = n0, tau = tau0, Scenario = 2, beta_true = beta_true0, id = Script_ID)
results3 = results1;results4 = results2
toc()
final.output = c(results1, results2)
saveRDS(final.output, file = paste0('test_', Script_ID, '.rds'))



