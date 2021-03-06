#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# 2020.06.16: Max Lindmark
#
# - Code to clean and merge BITS HH (Record with detailed haul information),
#   and CA (Sex-maturity-age–length keys (SMALK's) for ICES subdivision) data
#   directly from DATRAS. We want to end up with a dataset of length-at-weight of cod,
#   with haul information.
# 
#   Next, we join in CPUE (Catch in numbers per hour of hauling) of flounder and cod
#   We calculate this for two size classes by species. If the haul is not in the catch
#   data, give a 0 catch
# 
#   After that, we join in the abundance of sprat and herring. This is available on 
#   an ICES rectangle-level, so many hauls will end up with the same abundance
# 
#   Lastly, we join in OCEANOGRAPHIC data (oxygen, temperature).This is model output
#   from NEMO_Nordic_SCOBI, downloaded from:
#   https://resources.marine.copernicus.eu/?option=com_csw&task=results
#
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# A. LOAD LIBRARIES ================================================================
# rm(list = ls())

# Load libraries, install if needed
library(tidyverse); theme_set(theme_classic())
library(readxl)
library(tidylog)
library(RCurl)
library(viridis)
library(RColorBrewer)
library(patchwork)
library(janitor)
library(icesDatras)
library(mapdata)
library(patchwork)
library(rgdal)
library(raster)
library(sf)
library(rgeos)
library(chron)
library(lattice)
library(ncdf4)
library(sdmTMB) # remotes::install_github("pbs-assess/sdmTMB")
library(marmap)
library(rnaturalearth)
library(rnaturalearthdata)

# Print package versions
# sessionInfo()
# other attached packages:
# [1] sf_0.9-5           raster_3.3-13      rgdal_1.5-12       sp_1.4-2           mapdata_2.3.0      maps_3.3.0         ggsidekick_0.0.2  
# [8] icesDatras_1.3-0   janitor_2.0.1      patchwork_1.0.1    RColorBrewer_1.1-2 viridis_0.5.1      viridisLite_0.3.0  RCurl_1.98-1.2    
# [15] tidylog_1.0.2      readxl_1.3.1       forcats_0.5.0      stringr_1.4.0      dplyr_1.0.0        purrr_0.3.4        readr_1.3.1       
# [22] tidyr_1.1.0        tibble_3.0.3       ggplot2_3.3.2      tidyverse_1.3.0 

# For adding maps to plots
world <- ne_countries(scale = "medium", returnclass = "sf")


# B. READ HAUL DATA ================================================================
# Load HH data using the DATRAS package to get catches
# bits_hh <- getDATRAS(record = "HH", survey = "BITS", years = 1991:2020, quarters = 1:4)

# write.csv("data/bits_hh.csv")
bits_hh <- read.csv("data/DATRAS_exchange/bits_hh.csv")

# Create ID column
bits_hh <- bits_hh %>% 
  mutate(ID = paste(Year, Quarter, Ship, Gear, HaulNo, StNo, sep = "."))

# Check that per ID, there's only one row
bits_hh %>%
  group_by(ID) %>% 
  mutate(n = n()) %>% 
  filter(n > 1) %>% 
  arrange(ID) %>% 
  as.data.frame()

# Check default availability of environmental data
ggplot(bits_hh, aes(BotSal)) + geom_histogram()
ggplot(bits_hh, aes(SurSal)) + geom_histogram()
ggplot(bits_hh, aes(BotTemp)) + geom_histogram()

# Plot haul-duration
ggplot(bits_hh, aes(HaulDur)) + geom_histogram()

# Select only useful columns, this is the dataframe used in the merge later on
bits_hh_filter <- bits_hh %>% dplyr::select(ID, ShootLat, ShootLong, StatRec, Depth,
                                            BotTemp,BotSal, Year, Quarter, HaulDur, 
                                            DataType, HaulVal)

# Test I only got 1 row per haul
bits_hh_filter %>% 
  group_by(ID) %>%
  mutate(n = n()) %>% 
  ggplot(., aes(factor(n))) + geom_bar()


# C. READ LENGTH-WEIGHT DATA =======================================================
# Load CA data using the DATRAS package to get catches
# Note we only want cod data here
# bits_ca <- getDATRAS(record = "CA", survey = "BITS", years = 1991:2020, quarters = 1:4)

# write.csv("data/bits_ca.csv")
bits_ca <- read.csv("data/DATRAS_exchange/bits_ca.csv")

# Filter only cod and positive length measurements
bits_ca <- bits_ca %>% filter(SpecCode %in% c("164712", "126436") & LngtClass > 0)

# Add new species-column
bits_ca$Species <- "Cod"

# Create ID column
bits_ca <- bits_ca %>% 
  mutate(ID = paste(Year, Quarter, Ship, Gear, HaulNo, StNo, sep = "."))

# Check that per ID AND LNGTCLASS, there's only one row
bits_ca %>% 
  mutate(TEST = paste(ID, LngtClass)) %>% 
  group_by(TEST) %>% 
  mutate(n = n()) %>% 
  ungroup() %>%
  ggplot(., aes(factor(n))) + geom_bar()

# Now I need to copy rows with NoAtLngt > 1 so that 1 row = 1 ind
# First make a small test
nrow(bits_ca)
head(filter(bits_ca, NoAtLngt == 5))
head(filter(bits_ca, ID == "1992.1.GFR.SOL.H20.33.42" & NoAtLngt == 5), 20)

bits_ca <- bits_ca %>% map_df(., rep, .$NoAtLngt)

head(data.frame(filter(bits_ca, ID == "1992.1.GFR.SOL.H20.33.42" & NoAtLngt == 5)), 20)
nrow(bits_ca)
# Looks ok!

# Standardize length
bits_ca <- bits_ca %>% 
  drop_na(IndWgt) %>% 
  drop_na(LngtClass) %>% 
  filter(IndWgt > 0 & LngtClass > 0) %>%  # Filter positive length and weight
  mutate(length_cm = ifelse(LngtCode == ".", 
                            LngtClass/10,
                            LngtClass)) %>% # Standardize length ((https://vocab.ices.dk/?ref=18))
  as.data.frame()
  
ggplot(bits_ca, aes(length_cm, fill = LngtCode)) + geom_histogram()


# D. JOIN CONDITION AND HAUL DATA ==================================================
# Check if any ID is in the HL but not HH data
# I will need to remove these because they do not have any spatial information
bits_ca$ID[!bits_ca$ID %in% bits_hh_filter$ID]

# And other way around (this is expected since we have hauls without catches or data 
# on condition)
bits_hh_filter$ID[!bits_hh_filter$ID %in% bits_ca$ID]

dat <- left_join(bits_ca, bits_hh_filter)

# Remove the NA latitudes and we remove all the IDs that were in the bits_ca but not 
# in the haul data
dat <- dat %>% drop_na(ShootLat)

# Plot spatial distribution of samples
# dat %>% 
#   ggplot(., aes(y = ShootLat, x = ShootLong)) +
#   geom_point(size = 0.3) +
#   facet_wrap(~ Year) + 
#   theme_bw() +
#   geom_sf(data = world, inherit.aes = F, size = 0.2) +
#   coord_sf(xlim = c(8, 25), ylim = c(54, 60)) +
#   NULL

# Lastly we can remove hauls from outside the study area (Kattegatt basically)
# select only quarter 4 and remove non-valid hauls
dat <- dat %>% 
  filter(ShootLat < 58) %>% 
  mutate(kattegatt = ifelse(ShootLat > 56 & ShootLong < 14, "Y", "N")) %>% 
  filter(kattegatt == "N",
         Quarter == 4,
         HaulVal == "V") %>% 
  dplyr::select(-kattegatt)

# Plot again:
# Plot spatial distribution of samples
# dat %>% 
#   ggplot(., aes(y = ShootLat, x = ShootLong)) +
#   geom_point(size = 0.3) +
#   facet_wrap(~ Year) + 
#   theme_bw() +
#   geom_sf(data = world, inherit.aes = F, size = 0.2) +
#   coord_sf(xlim = c(8, 25), ylim = c(54, 60)) +
#   NULL

min(dat$ShootLon)

# E. READ AND JOIN THE COD AND FLOUNDER COVARIATES =================================
cov_dat <- read.csv("data/DATRAS_cpue_length_haul/CPUE per length per haul per hour_2020-09-25 16_15_36.csv")

# Remove hauls from outside the study area and select only quarter 4
cov_dat <- cov_dat %>% 
  filter(ShootLat < 58) %>% 
  mutate(kattegatt = ifelse(ShootLat > 56 & ShootLong < 14, "Y", "N")) %>% 
  filter(kattegatt == "N") %>% 
  filter(Quarter == 4) %>% 
  dplyr::select(-kattegatt)

# I am now going to assume that a haul that is present in the condition data but not
# in this covariate data means that the catch is 0
cov_dat %>% arrange(CPUE_number_per_hour)
cov_dat %>% filter(CPUE_number_per_hour == 0)

# Create a new ID column. Note that I can't define a single ID column that works for
# all data sets. The ID that I used for the Exchange data cannot be applied here. I
# need to come up with a new ID here. Run this to see common columns:
# colnames(dat)[colnames(dat) %in% colnames(cov_dat)]
# First filter by species and convert length to cm, then add in ID

cod <- cov_dat %>%
  filter(Species == "Gadus morhua") %>% 
  mutate(length_cm = LngtClass/10) %>% 
  filter(LngtClass > 0) %>% 
  mutate(ID2 = paste(Year, Quarter, Ship, Gear, HaulNo, Depth, ShootLat, ShootLong, sep = "."))

fle <- cov_dat %>%
  filter(Species == "Platichthys flesus") %>% 
  mutate(length_cm = LngtClass/10) %>% 
  filter(LngtClass > 0) %>% 
  mutate(ID2 = paste(Year, Quarter, Ship, Gear, HaulNo, Depth, ShootLat, ShootLong, sep = "."))

# First check if this is unique by haul. Then I should get 1 row per ID and size...
cod %>%
  group_by(ID2, LngtClass) %>% 
  mutate(n = n()) %>% 
  ungroup() %>% 
  distinct(n, .keep_all = TRUE) %>% 
  as.data.frame()

fle %>%
  group_by(ID2, LngtClass) %>% 
  mutate(n = n()) %>% 
  ungroup() %>% 
  distinct(n, .keep_all = TRUE) %>% 
  as.data.frame()

# And add also the same ID to dat (condition and haul data).
# Check if unique!
# It is with the exception of 8 rows. Not much I can do about that because I don't have
# any more unique columns I can add to the ID
test <- read.csv("data/DATRAS_exchange/bits_hh.csv")
test <- test %>%
  mutate(ID2 = paste(Year, Quarter, Ship, Gear, HaulNo, Depth, ShootLat, ShootLong, sep = "."))

test %>%
  mutate(ID2 = paste(Year, Quarter, Ship, Gear, HaulNo, Depth, ShootLat, ShootLong, sep = ".")) %>%
  group_by(ID2) %>%
  mutate(n = n()) %>%
  ungroup() %>%
  filter(!n==1) %>%
  as.data.frame()

# Test if these are in dat:
test_ids <- unique(test$ID2)

# Add in ID2
dat <- dat %>%
  mutate(ID2 = paste(Year, Quarter, Ship, Gear, HaulNo, Depth, ShootLat, ShootLong, sep = "."))

# No they are not, no need to filter.
filter(dat, ID2 %in% test_ids)

# Are there any ID's that are IN the covariate data that are not in the test
# (raw haul data) data?
cod$ID2[!cod$ID2 %in% test$ID2]
fle$ID2[!fle$ID2 %in% test$ID2]

filter(fle, ID2 %in% unique(test$ID2)) 
# Nope! All good.

# Now calculate the mean CPUE per hauls and size group per species. For cod we use 30
# cm and for flounder 20 cm. This is because Neuenfeldt et al (2019) found that cod
# below 30cm are in a growth-bottleneck, and because Haase et al (2020) found that 
# flounder above 20cm start feeding a lot of saduria, which has been speculated to
# decline in cod stomachs due to interspecific competition and increased spatial
# overlap with flounder.
cod_above_30cm <- cod %>% 
  filter(length_cm >= 30) %>% 
  group_by(ID2) %>% 
  summarise(cpue_cod_above_30cm = sum(CPUE_number_per_hour)) %>% 
  ungroup()

cod_below_30cm <- cod %>% 
  filter(length_cm < 30) %>% 
  group_by(ID2) %>% 
  summarise(cpue_cod_below_30cm = sum(CPUE_number_per_hour)) %>% 
  ungroup()

fle_above_20cm <- fle %>% 
  filter(length_cm >= 20) %>% 
  group_by(ID2) %>% 
  summarise(cpue_fle_above_20cm = sum(CPUE_number_per_hour)) %>% 
  ungroup()

fle_below_20cm <- fle %>% 
  filter(length_cm < 20) %>% 
  group_by(ID2) %>% 
  summarise(cpue_fle_below_20cm = sum(CPUE_number_per_hour)) %>% 
  ungroup()

# Test it worked, first by plotting n rows per ID
cod_above_30cm %>% group_by(ID2) %>% mutate(n = n()) %>% 
  ggplot(., aes(factor(n))) + geom_bar()

# Next by calculating an example
unique(cod_above_30cm$ID2)

cod_above_30cm %>% filter(ID2 == "2003.4.DAN2.TVL.13.66.55.3736.16.9982")
sum(filter(cod, ID2 == "2003.4.DAN2.TVL.13.66.55.3736.16.9982" &
             length_cm >= 30)$CPUE_number_per_hour)

# Correct! The data subset yields the same 

# Join covariates
cod_above_30cm
cod_below_30cm
fle_above_20cm
fle_below_20cm

# Some rows are not present in the condition data (dat) but are in the CPUE data.
# As I showed above, all ID2's in the CPUE data are in the raw haul data, so if they 
# aren't with us anymore that means they have been filtered away along the road.
# I don't need to remove those ID2's though because when using left_join I keep only
# rows in x!
# cod_above_30cm$ID2[!cod_above_30cm$ID2 %in% test$ID2]

# Left join dat and cpue data (cod_above_30cm)
dat <- left_join(dat, cod_above_30cm) 

# Left join dat and cpue data (cod_below_30cm)
dat <- left_join(dat, cod_below_30cm) 

# Left join dat and cpue data (fle_above_20cm)
dat <- left_join(dat, fle_above_20cm) 

# Left join dat and cpue data (fle_below_20cm)
dat <- left_join(dat, fle_below_20cm) 

head(dat)

dat

# Again, I'm assuming here that NA means 0 catch, because there were no catches by that 
# haul in the CPUE data. Testing a random ID2 that the covariate is repeated within haul
unique(dat$ID2)

filter(dat, ID2 == "2004.4.SOL2.TVS.53.42.55.1918.13.2392")
filter(dat, ID2 == "2003.4.BAL.TVL.23.62.54.55.15.65")

# Replace NA catches with 0
dat$cpue_cod_above_30cm[is.na(dat$cpue_cod_above_30cm)] <- 0
dat$cpue_cod_below_30cm[is.na(dat$cpue_cod_below_30cm)] <- 0
dat$cpue_fle_above_20cm[is.na(dat$cpue_fle_above_20cm)] <- 0
dat$cpue_fle_below_20cm[is.na(dat$cpue_fle_below_20cm)] <- 0

filter(dat, ID2 == "2004.4.SOL2.TVS.53.42.55.1918.13.2392")
filter(dat, ID2 == "2003.4.BAL.TVL.23.62.54.55.15.65")

# Create total CPUE column
dat <- dat %>% mutate(cpue_cod = cpue_cod_above_30cm + cpue_cod_below_30cm,
                      cpue_fle = cpue_fle_above_20cm + cpue_fle_below_20cm)

# Final check, use random ID2's and compare them in cod/fle and test
cod$ID2[cod$ID2 %in% dat$ID2]

cod %>% filter(ID2 == "1992.4.SOL.H20.42.20.54.5.14.2")
dat %>% filter(ID2 == "1992.4.SOL.H20.42.20.54.5.14.2")

sum(filter(cod, ID2 == "1991.4.SOL.H20.30.26.54.6.14.25" & length_cm >= 30)$CPUE_number_per_hour)
sum(filter(cod, ID2 == "1991.4.SOL.H20.30.26.54.6.14.25" & length_cm < 30)$CPUE_number_per_hour)
dat %>% filter(ID2 == "1991.4.SOL.H20.30.26.54.6.14.25") %>%
  dplyr:: select(ID2, cpue_cod_above_30cm, cpue_cod_below_30cm)

fle %>% filter(ID2 == "1992.4.SOL.H20.42.20.54.5.14.2")
dat %>% filter(ID2 == "1992.4.SOL.H20.42.20.54.5.14.2")

sum(filter(fle, ID2 == "1991.4.SOL.H20.30.26.54.6.14.25" & length_cm >= 20)$CPUE_number_per_hour)
sum(filter(fle, ID2 == "1991.4.SOL.H20.30.26.54.6.14.25" & length_cm < 20)$CPUE_number_per_hour)
dat %>% filter(ID2 == "1991.4.SOL.H20.30.26.54.6.14.25") %>%
  dplyr:: select(ID2, cpue_fle_above_20cm, cpue_fle_below_20cm)


# F. READ AND JOIN PELAGIC COVARIATES ==============================================
spr <- read_xlsx("data/BIAS/abundances_rectangles_1991-2019.xlsx",
                 sheet = 1) %>%
  rename("StatRec" = "Rec") %>%
  mutate(StatRec = as.factor(StatRec),
         Species = "Sprat",
         abun_spr = `Age 0`+`Age 1`+`Age 2`+`Age 3`+`Age 4`+`Age 5`+`Age 6`+`Age 7`+`Age 8+`+`1+`,
         ID3 = paste(StatRec, Year, sep = ".")) # Make new ID)
  
her <- read_xlsx("data/BIAS/abundances_rectangles_1991-2019.xlsx",
                 sheet = 2) %>%
  as.data.frame() %>%
  rename("StatRec" = "Rect2") %>% # This is not called Rec in the data for some reason
  mutate(StatRec = as.factor(StatRec),
         Species = "Herring",
         abun_her = `Age 0`+`Age 1`+`Age 2`+`Age 3`+`Age 4`+`Age 5`+`Age 6`+`Age 7`+`Age 8+`+`1+`,
         ID3 = paste(StatRec, Year, sep = ".")) # Make new ID

# Check distribution of data
# https://www.researchgate.net/publication/47933620_Environmental_factors_and_uncertainty_in_fisheries_management_in_the_northern_Baltic_Sea/figures?lo=1
sort(unique(spr$SD))
sort(unique(her$SD))

# How many unique rows per ID3?
her %>%
  group_by(ID3) %>% 
  mutate(n = n()) %>% 
  ggplot(., aes(factor(n))) + geom_bar()

spr %>%
  group_by(ID3) %>% 
  mutate(n = n()) %>% 
  ggplot(., aes(factor(n))) + geom_bar()

# Ok, some ID's with two rows...
test_spr <- spr %>%
  group_by(ID3) %>% 
  mutate(n = n()) %>% 
  filter(n == 2) %>% 
  ungroup() %>% 
  as.data.frame()

test_spr

# Seems to be due to rectangles somehow being in different sub divisions. I need to
# group by ID3 and summarize
nrow(spr)
nrow(spr %>% group_by(ID3) %>% mutate(n = n()) %>% filter(n == 2))
nrow(spr %>% group_by(ID3) %>% mutate(n = n()) %>% filter(!n == 1))

spr_sum <- spr %>%
  group_by(ID3) %>% 
  summarise(abun_spr = sum(abun_spr)) %>% # Sum abundance within ID3
  distinct(ID3, .keep_all = TRUE) %>% # Remove duplicate ID3
  mutate(ID_temp = ID3) %>% # Create temporary ID3 that we can use to split in order
                            # to get Year and StatRect back into the summarized data
  separate(ID_temp, c("StatRec", "Year"), sep = 4)

nrow(spr_sum) 
nrow(spr)
nrow(spr %>% group_by(ID3) %>% mutate(n = n()) %>% filter(n == 2))

filter(spr_sum, ID3 == "39G2.1991")
filter(spr, ID3 == "39G2.1991")

# This should equal 1 (new # rows =  old - duplicated ID3)
nrow(spr_sum) / (nrow(spr) - 0.5*nrow(spr %>% group_by(ID3) %>% mutate(n = n()) %>% filter(n == 2)))

# Join pelagic covariates
# Make StatRec a factor in the main data
dat <- dat %>% mutate(StatRec = as.factor(StatRec))
unique(is.na(dat$StatRec))

# Create ID3 to match pelagics data
dat <- dat %>% mutate(ID3 = paste(StatRec, Year, sep = "."))

# Are there any StatRec that are in the condition data that are not in the pelagics data?
dat$StatRec[!dat$StatRec %in% her$StatRec]
dat$StatRec[!dat$StatRec %in% spr$StatRec]

# No, but not all ID3's are present
dat$ID3[!dat$ID3 %in% her$ID3]
dat$ID3[!dat$ID3 %in% spr$ID3]

filter(dat, ID3 == "44G8.1991")
filter(her, ID3 == "44G8.1991")

filter(dat, StatRec == "44G8")
filter(her, StatRec == "44G8")

# Select columns from pelagic data to go in dat
spr_sub <- spr %>% dplyr::select(ID3, abun_spr)
her_sub <- her %>% dplyr::select(ID3, abun_her)

# Now join dat and sprat data
dat <- left_join(dat, spr_sub)

# And herring..
dat <- left_join(dat, her_sub)

# REPLACE NA ABUNDANCES WITH 0
dat$abun_her[is.na(dat$abun_her)] <- 0
dat$abun_spr[is.na(dat$abun_spr)] <- 0

unique(is.na(dat$abun_spr))

# Test an ID3 in spr/her and dat
# > head(unique(dat$ID3))
# [1] "39G4.1991" "40G4.1991" "43G7.1991" "44G8.1991" "44G9.1991" "44G7.1991"
spr %>% filter(ID3 == "44G7.1991")
her %>% filter(ID3 == "44G7.1991")
dat %>% filter(ID3 == "44G7.1991")

# Plot distribution of abundances
ggplot(dat, aes(abun_spr)) + geom_histogram()
ggplot(dat, aes(abun_her)) + geom_histogram()

# How to select which ages to use as predictor variables?
# From Niiranen et al, it seem sprat in cod stomachs range between 50 and 150 mm and
# herring range between essentially 0 to 300 mm. Which ages does that correspond to? For
# that we need VBGE parameters. Following Lindmark et al (in prep), in which the VBGE 
# curves are plotted for these species for weight, and weight-length relationships are 
# estimated, we see the following:

# Sprat: a 5 and 15 cm sprat weighs 1 and 30 g respectively. 
0.0078*5^3.07
0.0078*15^3.07
# This covers all weights and ages in the sprat data. Moreover, in Niiranen et al it
# doesn't seem to be much variation between size classes of cod with respect to this.

# Herring: a 1 and 30 cm herring weighs >1 and 182 g respectively. 
0.0042*1^3.14
0.0042*30^3.14
# This covers all weights and ages in the herring data. Moreover, in Niiranen et al it
# doesn't seem to be much variation between size classes of cod with respect to this.

# Conclusion: I will not filter any further


# # G. READ AND JOIN OCEANOGRAPHIC DATA ==============================================
# ** Oxygen ========================================================================
# Downloaded from here: https://resources.marine.copernicus.eu/?option=com_csw&view=details&product_id=BALTICSEA_REANALYSIS_BIO_003_012
# Extract raster points: https://gisday.wordpress.com/2014/03/24/extract-raster-values-from-points-using-r/comment-page-1/
# https://rpubs.com/boyerag/297592
# https://pjbartlein.github.io/REarthSysSci/netCDF.html#get-a-variable
# Open the netCDF file
ncin <- nc_open("data/NEMO_Nordic_SCOBI/dataset-reanalysis-scobi-monthlymeans_1603971995426.nc")

print(ncin)

# Get longitude and latitude
lon <- ncvar_get(ncin,"longitude")
nlon <- dim(lon)
head(lon)

lat <- ncvar_get(ncin,"latitude")
nlat <- dim(lat)
head(lat)

# Get time
time <- ncvar_get(ncin,"time")
time

tunits <- ncatt_get(ncin,"time","units")
nt <- dim(time)
nt
tunits

# Get oxygen
dname <- "o2b"

oxy_array <- ncvar_get(ncin,dname)
dlname <- ncatt_get(ncin,dname,"long_name")
dunits <- ncatt_get(ncin,dname,"units")
fillvalue <- ncatt_get(ncin,dname,"_FillValue")
dim(oxy_array)

# Get global attributes
title <- ncatt_get(ncin,0,"title")
institution <- ncatt_get(ncin,0,"institution")
datasource <- ncatt_get(ncin,0,"source")
references <- ncatt_get(ncin,0,"references")
history <- ncatt_get(ncin,0,"history")
Conventions <- ncatt_get(ncin,0,"Conventions")

# Convert time: split the time units string into fields
tustr <- strsplit(tunits$value, " ")
tdstr <- strsplit(unlist(tustr)[3], "-")
tmonth <- as.integer(unlist(tdstr)[2])
tday <- as.integer(unlist(tdstr)[3])
tyear <- as.integer(unlist(tdstr)[1])

# Here I deviate from the guide a little bit. Save this info:
dates <- chron(time, origin = c(tmonth, tday, tyear))

# Crop the date variable
months <- as.numeric(substr(dates, 2, 3))
years <- as.numeric(substr(dates, 8, 9))
years <- ifelse(years > 90, 1900 + years, 2000 + years)

# Replace netCDF fill values with NA's
oxy_array[oxy_array == fillvalue$value] <- NA

# We only use Quarter 4 in this analysis, so now we want to loop through each time step,
# and if it is a good month save it as a raster.
# First get the index of months that correspond to Q4
months

index_keep <- which(months > 9)

oxy_q4 <- oxy_array[, , index_keep]

months_keep <- months[index_keep]

years_keep <- years[index_keep]

# Now we have an array with only Q4 data...
# We need to now calculate the average within a year.
# Get a sequence that takes every third value between 1: number of months (length)
loop_seq <- seq(1, dim(oxy_q4)[3], by = 3)

# Create objects that will hold data
dlist <- list()
oxy_10 <- c()
oxy_11 <- c()
oxy_12 <- c()
oxy_ave <- c()

# Loop through the vector sequence with every third value, then take the average of
# three consecutive months (i.e. q4)
for(i in loop_seq) {

  oxy_10 <- oxy_q4[, , (i)]
  oxy_11 <- oxy_q4[, , (i + 1)]
  oxy_12 <- oxy_q4[, , (i + 2)]

  oxy_ave <- (oxy_10 + oxy_11 + oxy_12) / 3

  list_pos <- ((i/3) - (1/3)) + 1 # to get index 1:n(years)

  dlist[[list_pos]] <- oxy_ave

}

# Now name the lists with the year:
names(dlist) <- unique(years_keep)

# Now I need to make a loop where I extract the raster value for each year...
# The condition data is called dat so far in this script

# Filter years in the condition data frame to only have the years I have oxygen for
d_sub_oxy <- dat %>% filter(Year %in% names(dlist)) %>% droplevels()

# Create data holding object
data_list <- list()

# ... And for the oxygen raster
raster_list <- list()

# Create factor year for indexing the list in the loop
d_sub_oxy$Year_f <- as.factor(d_sub_oxy$Year)

# Loop through each year and extract raster values for the condition data points
for(i in unique(d_sub_oxy$Year_f)) {

  # Subset a year
  oxy_slice <- dlist[[i]]

  # Create raster for that year (i)
  r <- raster(t(oxy_slice), xmn = min(lon), xmx = max(lon), ymn = min(lat), ymx = max(lat),
              crs = CRS("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs+ towgs84=0,0,0"))

  # Flip...
  r <- flip(r, direction = 'y')

  plot(r, main = i)

  # Filter the same year (i) in the condition data and select only coordinates
  d_slice <- d_sub_oxy %>% filter(Year_f == i) %>% dplyr::select(ShootLong, ShootLat)

  # Make into a SpatialPoints object
  data_sp <- SpatialPoints(d_slice)

  # Extract raster value (oxygen)
  rasValue <- raster::extract(r, data_sp)

  # Now we want to plot the results of the raster extractions by plotting the condition
  # data points over a raster and saving it for each year.
  # Make the SpatialPoints object into a raster again (for pl)
  df <- as.data.frame(data_sp)

  # Add in the raster value in the df holding the coordinates for the condition data
  d_slice$oxy <- rasValue

  # Add in which year
  d_slice$year <- i

  # Create a index for the data last where we store all years (because our loop index
  # i is not continuous, we can't use it directly)
  index <- as.numeric(d_slice$year)[1] - 1992

  # Add each years' data in the list
  data_list[[index]] <- d_slice

  # Save to check each year is ok! First convert the raster to points for plotting
  # (so that we can use ggplot)
  map.p <- rasterToPoints(r)

    # Make the points a dataframe for ggplot
  df_rast <- data.frame(map.p)

  # Rename y-variable and add year
  df_rast <- df_rast %>% rename("oxy" = "layer") %>% mutate(year = i)

  # Add each years' raster data frame in the list
  raster_list[[index]] <- df_rast

  # Make appropriate column headings
  colnames(df_rast) <- c("Longitude", "Latitude", "oxy")

  # Now make the map
  ggplot(data = df_rast, aes(y = Latitude, x = Longitude)) +
    geom_raster(aes(fill = oxy)) +
    geom_point(data = d_slice, aes(x = ShootLong, y = ShootLat, fill = oxy),
               color = "black", size = 5, shape = 21) +
    theme_bw() +
    geom_sf(data = world, inherit.aes = F, size = 0.2) +
    coord_sf(xlim = c(min(dat$ShootLong), max(dat$ShootLong)),
             ylim = c(min(dat$ShootLat), max(dat$ShootLat))) +
    scale_colour_gradientn(colours = rev(terrain.colors(10)),
                           limits = c(-200, 400)) +
    scale_fill_gradientn(colours = rev(terrain.colors(10)),
                         limits = c(-200, 400)) +
    NULL

    ggsave(paste("figures/supp/oxygen_rasters/", i,".png", sep = ""),
         width = 6.5, height = 6.5, dpi = 600)

}

# Now create a data frame from the list of all annual values
big_dat_oxy <- dplyr::bind_rows(data_list)
big_raster_dat_oxy <- dplyr::bind_rows(raster_list)

# Plot data, looks like there's big inter-annual variation but a negative
big_raster_dat_oxy %>%
  group_by(year) %>%
  drop_na(oxy) %>%
  summarise(mean_oxy = mean(oxy)) %>%
  mutate(year_num = as.numeric(year)) %>%
  ggplot(., aes(year_num, mean_oxy)) +
  geom_point(size = 2) +
  stat_smooth(method = "lm") +
  NULL

big_raster_dat_oxy %>%
  group_by(year) %>%
  drop_na(oxy) %>%
  mutate(dead = ifelse(oxy < 0, "Y", "N")) %>%
  filter(dead == "Y") %>%
  mutate(n = n(),
         year_num = as.numeric(year)) %>%
  ggplot(., aes(year_num, n)) +
  geom_point(size = 2) +
  stat_smooth(method = "lm") +
  NULL

# Now add in the new oxygen column in the original data:
str(d_sub_oxy)
str(big_dat_oxy)

# Create an ID for matching the oxygen data with the condition data
dat$id_oxy <- paste(dat$Year, dat$ShootLong, dat$ShootLat, sep = "_")
big_dat_oxy$id_oxy <- paste(big_dat_oxy$year, big_dat_oxy$ShootLong, big_dat_oxy$ShootLat, sep = "_")

# Which id's are not in the condition data (dat)?
ids <- dat$id_oxy[!dat$id_oxy %in% c(big_dat_oxy$id_oxy)]

unique(ids)

# Select only the columns we want to merge
big_dat_sub_oxy <- big_dat_oxy %>% dplyr::select(id_oxy, oxy)

# Remove duplicate ID (one oxy value per id)
big_dat_sub_oxy2 <- big_dat_sub_oxy %>% distinct(id_oxy, .keep_all = TRUE)

# Join the data with raster-derived oxygen with the full condition data
dat <- left_join(dat, big_dat_sub_oxy2, by = "id_oxy")

# ** Temperature ===================================================================
# Open the netCDF file
# This is currently very bugged... see example below in local folder!


# H. PREPARE DATA FOR ANALYSIS =====================================================
d <- dat %>%
  rename("weight_g" = "IndWgt",
         "lat" = "ShootLat",
         "lon" = "ShootLong",
         "year" = "Year",
         "sex" = "Sex",
         "depth" = "Depth") %>% 
  mutate(ln_weight_g = log(weight_g),
         ln_length_cm = log(length_cm),
         Fulton_K = weight_g/(0.01*length_cm^3), # cod-specific, from FishBase
         sex = ifelse(sex == -9, "U", sex),
         sex = as.factor(sex),
         year_f = as.factor(year)) %>% 
  dplyr::select(year, year_f, depth, StatRec, lat, lon, sex, length_cm, weight_g, ln_length_cm, ln_weight_g,
                Quarter, Fulton_K,
                cpue_cod_above_30cm, cpue_cod_below_30cm, cpue_cod, 
                cpue_fle_above_20cm, cpue_fle_below_20cm, cpue_fle,
                abun_spr, abun_her,
                oxy) %>% 
  mutate(depth_st = depth,
         cpue_cod_above_30cm_st = cpue_cod_above_30cm,
         cpue_cod_below_30cm_st = cpue_cod_below_30cm,
         cpue_cod_st = cpue_cod,
         cpue_fle_above_20cm_st = cpue_fle_above_20cm,
         cpue_fle_below_20cm_st = cpue_fle_below_20cm,
         cpue_fle_st = cpue_fle,
         abun_spr_st = abun_spr,
         abun_her_st = abun_her,
         oxy_st = oxy) %>% 
  mutate_at(c("depth_st",
              "cpue_cod_above_30cm_st", "cpue_cod_below_30cm_st", "cpue_cod_st",
              "cpue_fle_above_20cm_st", "cpue_fle_below_20cm_st", "cpue_fle_st",
              "abun_spr_st", "abun_her_st",
              "oxy_st"),
            ~(scale(.) %>% as.vector)) %>% 
  filter(Fulton_K < 3 & Fulton_K > 0.15) %>%  # Visual exploration, larger values likely data entry errors
  drop_na(oxy_st) %>% 
  filter(depth > 0) %>% 
  ungroup()

# filter(d, Fulton_K < 0.5) %>% dplyr::select(Fulton_K, length_cm, weight_g) %>% arrange(Fulton_K) %>% as.data.frame()
# filter(d, Fulton_K > 2.5) %>% dplyr::select(Fulton_K, length_cm, weight_g) %>% arrange(Fulton_K) %>% as.data.frame()

write.csv(d, file = "data/for_analysis/mdat_cond.csv", row.names = FALSE)
