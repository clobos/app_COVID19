rm(list=ls())

setwd("/home/marcosop/Covid/R/STAN")

###################################################################
### Packages
###################################################################
library(dplyr)
library(tidyr)
library(matrixStats)
library(mcmcplots)
library(MCMCvis)
library(foreach)
library(doMC)
library(rstan)                              
rstan_options(auto_write = TRUE)
###################################################################
### Data sets: https://github.com/CSSEGISandData
###################################################################
baseURLbr = "https://raw.githubusercontent.com/covid19br/covid19br.github.io/master/dados"

covid19uf <- read.csv(file.path(baseURLbr,"EstadosCov19.csv"), check.names=FALSE, stringsAsFactors=FALSE) %>%
#covid19uf <- read.csv2("EstadosCov19.csv", check.names=FALSE, stringsAsFactors=FALSE) %>%
  rename(state = estado,
         date = data,
         n = casos.acumulados,
         d = obitos.acumulados,
         n_new = novos.casos,
         d_new = obitos.novos) %>%
  mutate(date = as.Date(date)) %>%
#  mutate(date = as.Date(date, "%d/%m/%y")) %>%
  select(date, n, d, -n_new, -d_new, state) %>%
#  select(date, -n, -d, n_new, d_new, state) %>%
#  na.omit() %>%
  arrange(state,date) %>% filter(date>='2020-01-23')

covid19br <- read.csv(file.path(baseURLbr,"BrasilCov19.csv"), check.names=FALSE, stringsAsFactors=FALSE) %>%
#covid19br <- read.csv2("BrasilCov19.csv", check.names=FALSE, stringsAsFactors=FALSE) %>%
  mutate(state = 'BR') %>%
  rename(date = data,
         n = casos.acumulados,
         d = obitos.acumulados,
         n_new = novos.casos,
         d_new = obitos.novos) %>%
  mutate(date = as.Date(date)) %>%
#  mutate(date = as.Date(date, "%d/%m/%y")) %>%
  select(date, n, d, -n_new, -d_new, state) %>%
#  select(date, -n, -d, n_new, d_new, state) %>%
#  na.omit() %>%
  arrange(date) %>% filter(date>='2020-01-23')

covid19 <- bind_rows(covid19uf,covid19br)
uf <- distinct(covid19,state)

br_pop <- read.csv("../pop/pop_BR.csv")

###########################################################################
###### JAGS /STAN
###########################################################################
#register cores
#registerDoMC(cores = detectCores()-1)    # Alternativa Linux
registerDoMC(cores = 27)    # Alternativa Linux

#complie stan model
model="stan_model_poisson_gen_fds.stan"    #modelo STAN 
mod<- try(stan_model(file = model,verbose=FALSE))

if(class(mod) == "try-error") stop("STAN DID NOT COMPILE")

#for ( s in 1:dim(uf)[1] ) {
obj <- foreach( s = 1:(dim(uf)[1]-1) ) %dopar% {
#obj <- foreach( s = 1:3 ) %dopar% {
  #source("jags_poisson.R")
  
  i = 5 # (2: confirmed, 3: deaths, 4: new confirmed, 5: new deaths)
  L = 300
  #t0 = Sys.time()
  estado = uf$state[s]
    
  Y <- covid19 %>% filter(state==estado) %>%
          mutate(n_new = n - lag(n, default=0),
          d_new = d - lag(d, default=0)) %>%
          select(date, n, d, n_new, d_new, state) %>%
          arrange(date) %>% filter(date>='2020-02-01')

  #Y <- covid19 %>% filter(state==estado) %>%
  #        mutate(n = cumsum(n_new) ,
  #        d = cumsum(d_new) ) %>%
  #        select(date, n, d, n_new, d_new, state) %>%
  #        arrange(date) %>% filter(date>='2020-02-01')

  #Y = covid19 %>% filter(state==uf$state[s])
  
  while(any(Y$d_new <0)){
    pos <- which(Y$d_new <0)
    for(j in pos){
      Y$d_new[j-1] = Y$d_new[j] + Y$d_new[j-1]
      Y$d_new[j] = 0
      Y$d[j-1] = Y$d[j]
    }
  }
  
  pop <- br_pop$pop[which(br_pop$uf == uf$state[s])]
  
  t = dim(Y)[1]
  
  params = c("a","b","c","f","beta_sunday", "beta_monday", "mu")
  # params = c("a","b","c","f", "mu")
  
  burn_in= 5e3
  lag= 3
  sample_size= 1e3
  number_iterations= burn_in + lag*sample_size
  number_chains= 1
  
  data_stan = list(y=Y[[i]], n=t, L=L, pop=.08*pop, perPop=0.25)  
  
  #changed
  ### Index the sundays in the vector of observations
  data_stan$index_sundays<- which(weekdays(Y$date) == "domingo")
  data_stan$n_sundays<- length(data_stan$index_sundays)
  
  ### Index the montdays in the vector of observations
  data_stan$index_mondays<- which(weekdays(Y$date) == "segunda")
  data_stan$n_mondays<- length(data_stan$index_mondays)
  
  ### Index the other days in the vector of observations
  data_stan$index_others<- which(!(weekdays(Y$date) %in% c("domingo", "segunda")))
  data_stan$n_others<- length(data_stan$index_others)
  
  init <- list(
    list(a = 100, b1 = log(1), c = .5, f = 1.01, beta_sunday1=1.01, beta_monday1=1.01) #changed
  )

  mod_sim<- try(sampling(object = mod, data = data_stan,
                         pars = params,
                         chains = number_chains,
                         init = init,
                         iter = number_iterations, warmup = burn_in, thin = lag, 
                         control = list(max_treedepth = 50, adapt_delta=0.999),
                         verbose = FALSE, open_progress=FALSE, show_messages=FALSE))
  
  {if(class(mod_sim) != "try-error"){
    
    mod_chain = as.data.frame(mod_sim)
    
    a_pos = "a"
    b_pos = "b"
    c_pos = "c"
    f_pos = "f"
    beta_sunday_pos <- "beta_sunday" #changed
    beta_monday_pos <- "beta_monday" #changed

    mu_pos = paste0("mu[",1:t,"]")
    yfut_pos = paste0("yfut[",1:L,"]")

    ### For prediction #changed
    aux_date<- seq(from = last(Y$date), by = "days", length.out = L + 1)[-1]
    index_sundays_prediction<- which(weekdays(aux_date) == "domingo")
    #n_sundays_prediction<- length(index_sundays_prediction)
    index_mondays_prediction<- which(weekdays(aux_date) == "segunda")
    #n_mondays_prediction<- length(index_mondays_prediction)
    index_others_prediction<- which(!(weekdays(aux_date) %in% c("domingo", "segunda")))
    #n_others_prediction<- length(index_others_prediction)
    
    source("posterior_sample.R")
    fut <- predLW(L=L,t,pop,Y[[2]][t],c(mod_chain[[a_pos]]),c(mod_chain[[b_pos]]),c(mod_chain[[c_pos]]),c(mod_chain[[f_pos]]),
                  c(mod_chain[[beta_sunday_pos]]),c(mod_chain[[beta_monday_pos]]),index=index_others_prediction, index.s=index_sundays_prediction,
                  index.m=index_mondays_prediction) #changed
    
    mod_chain_y = fut$y.fut
    #mod_chain_y = as.matrix(mod_chain[yfut_pos])
    mod_chain_cumy = rowCumsums(mod_chain_y) + Y[[3]][t]
    
    L0 = 14

    ### list output
    df_predict <- data.frame( date = as.Date((max(Y$date)+1):(max(Y$date)+L0), origin="1970-01-01"),
                              q25  = colQuantiles(mod_chain_cumy[,1:L0], prob=.025),
                              med  = colQuantiles(mod_chain_cumy[,1:L0], prob=.5),
                              q975 = colQuantiles(mod_chain_cumy[,1:L0], prob=.975),
                              m    = colMeans(mod_chain_cumy[,1:L0]))
    row.names(df_predict) <- NULL 
    
    lt_predict <- lt_summary <- NULL
    
    #longterm
    L0 = 300
    
    {if(Y[[3]][t] > 1000){
      #acha a curva de quantil 
      lowquant <- colQuantiles(mod_chain_y[,1:L0], prob=.025)
      medquant <- colQuantiles(mod_chain_y[,1:L0], prob=.5)
      highquant <- colQuantiles(mod_chain_y[,1:L0], prob=.975)
    }
    else{
      lowquant <- c(Y[[3]][t],colQuantiles(mod_chain_cumy[,1:L0], prob=.025))
      lowquant <- (lowquant-lag(lowquant,default=0))[-1]
      medquant <- c(Y[[3]][t],colQuantiles(mod_chain_cumy[,1:L0], prob=.5))
      medquant <- (medquant-lag(medquant,default=0))[-1]
      highquant <- c(Y[[3]][t],colQuantiles(mod_chain_cumy[,1:L0], prob=.975))
      highquant <- (highquant-lag(highquant,default=0))[-1]
    }}

    NTC25 =sum(lowquant)+Y[[3]][t]
    NTC500=sum(medquant)+Y[[3]][t]
    NTC975=sum(highquant)+Y[[3]][t]
    
    
    ##flag
    cm <- pop * 0.08 * 0.25
    ch <- pop * 0.12 * 0.25
    flag <- 0 #tudo bem
    {if(NTC500 > cm) flag <- 2 #nao plotar
      else{if(NTC975 > ch){flag <- 1; NTC25 <- NTC975 <- NULL}}} #plotar so mediana
    
    #vetor de data futuras e pega a posicao do maximo do percentil 25.
    dat.vec <- as.Date((max(Y$date)+1):(max(Y$date)+L0), origin="1970-01-01")
    dat.full <- c(Y[[1]],dat.vec)

    index_week <- which(!(weekdays(dat.full) %in% c("domingo", "segunda"))) #change
    
    Dat25 <- Dat500 <- Dat975 <- NULL
    dat.low.end <- dat.med.end <- dat.high.end <- NULL
    
    #mod_chain_mu = as.matrix(mod_chain[mu_pos])
    ifelse(length(fut$pos) > 0,
           mod_chain_mu <- cbind(as.matrix(mod_chain[mu_pos])[-fut$pos,],fut$mu.fut),
           mod_chain_mu <- cbind(as.matrix(mod_chain[mu_pos]),fut$mu.fut))
    mu50 <- apply(mod_chain_mu,2,quantile, probs=0.5)
    Dat500 <- dat.full[which.max(mu50[1:(t+L0)])]
    
    q <- .99
    med.cum <- mu50#c(medquant[1]+Y[[2]][t],medquant[2:length(medquant)])
    med.cum <- colCumsums(as.matrix(med.cum))
    med.cum <- med.cum/med.cum[length(med.cum)]
    med.end <- which(med.cum - q > 0)[1]
    #dat.med.end <- dat.vec[med.end]
    dat.med.end <- dat.full[med.end]
    
    if(flag == 0){
      #definicao do pico usando a curva das medias
      mu25 <- apply(mod_chain_mu,2,quantile, probs=0.025)
      mu975 <- apply(mod_chain_mu,2,quantile, probs=.975)
      
      #posMax.q25 <- which.max(mu25[1:(t+L0)]) 
      mu25.aux <- mu25[index_week] #changed
      posMax.q25 <- which.max(mu25.aux) #changed
      aux <- mu975[index_week] - mu25.aux[posMax.q25] #changed
      aux2 <- aux[posMax.q25:length(aux)] #changed
      val <- ifelse(length(aux2[aux2<0]) > 0, min(aux2[aux2>0]), aux[length(aux)])
      dat.max <- which(aux == val)
      
      aux <- mu975[index_week] - mu25.aux[posMax.q25] #changed
      aux2 <- aux[1:posMax.q25]
      val <- min(aux2[aux2>0]) 
      dat.min <- which(aux == val)
      
      dat.full.aux <- dat.full[index_week] #changed
      Dat25 <- dat.full.aux[dat.min] #changed
      Dat975 <- dat.full.aux[dat.max] #changed
      
      #calcula o fim da pandemia
      low.cum <- mu25 #c(lowquant[1]+Y[[2]][t],lowquant[2:length(lowquant)])
      low.cum <- colCumsums(as.matrix(low.cum))
      low.cum <- low.cum/low.cum[length(low.cum)]
      low.end <- which(low.cum - q > 0)[1]
      #dat.low.end <- dat.vec[low.end]
      dat.low.end <- dat.full[low.end]
    
      high.cum <- mu975 #c(highquant[1]+Y[[2]][t],highquant[2:length(highquant)])
      high.cum <- colCumsums(as.matrix(high.cum))
      high.cum <- high.cum/high.cum[length(high.cum)]
      high.end <- which(high.cum - q > 0)[1]
      #dat.high.end <- dat.vec[high.end]
      dat.high.end <- dat.full[high.end]
    }
    
    lt_predict <- data.frame( date = dat.vec,
                              q25  = lowquant,
                              med  = medquant,
                              q975 = highquant,
                              m    = colMeans(mod_chain_y[,1:L0]))     
    row.names(lt_predict) <- NULL
    
    lt_summary <- list(NTC25=NTC25,
                       NTC500=NTC500,
                       NTC975=NTC975,
                       high.dat.low=Dat25,
                       high.dat.med=Dat500,
                       high.dat.upper=Dat975,
                       end.dat.low = dat.low.end,
                       end.dat.med = dat.med.end,
                       end.dat.upper = dat.high.end)
    
    muplot <- data.frame(date = dat.full, mu = mu50[1:(t+L0)])
    list_out <- list( df_predict = df_predict, lt_predict=lt_predict, lt_summary=lt_summary, mu_plot = muplot, flag=flag, mod_chain_y = mod_chain_y, mod_chain_mu = mod_chain_mu)
    
    ### saveRDS
    results_directory = "/home/marcosop/Covid/app_COVID19/STpredictions/"
    # results_directory = 'C:/Users/ricar/Dropbox/covid19/R/predict/'
    file_id <- ifelse(uf$state[s]=='BR', colnames(Y)[3] , paste0(uf$state[s],'_',colnames(Y)[3],'e'))
    saveRDS(list_out, file=paste0(results_directory,'Brazil_',file_id,'.rds'))
    
    ### report
    source("mcmcplot_country.R")
    report_directory = "/home/marcosop/Covid/app_COVID19/STpredictions/reports"
    # report_directory = 'C:/Users/ricar/Dropbox/covid19/R/predict/report'
    #mcmcplot_country(mcmcout = mod_sim, parms = c(paste0("a[",t,"]"), paste0("b[",t,"]"), paste0("c[",t,"]")),
    mcmcplot_country(mcmcout = MCMCchains(object = mod_sim, mcmc.list = TRUE), parms = c("a", "b", "c", "f", "beta_sunday",
                                                                                         "beta_monday"),
                     dir = report_directory,
                     filename = paste0('Brazil_',file_id,'_diagnostics'),
                     heading = paste0('Brazil_',file_id),
                     extension = "html", greek = TRUE,
                     country = 'Brazil',
                     type = file_id)

    
    ### run time
    #run_time = round(as.numeric(Sys.time()-t0, units="mins"),2)
    #print(noquote(paste(run_time, "minutes to", uf$state[s])))
    
  }
  
  else print(paste0("ERROR:",uf$state[s]))}
  
}
