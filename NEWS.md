# setupRxNorm 1.7.0

* Added 04-Apr-2022 RxClass Data version 19  

* Changed output directory from inst due to compression 
issues  


# setupRxNorm 1.6.0  

* Add 07-Mar-2022 RxClass Data  


# setupRxNorm 1.5.0  

## RxNorm Proper  

* `run_setup()` arguments updated to represent the 2 additional 
schemas that processed tables are written to: RxRel and RxTra. 
RxRel contains tables laterally map between RxNorm tty while 
RxTra are tables with RxNorm data that has been enhanced with 
data pulled directly from the RxNorm API somehow such as 
RxCUI data for RxCUIs no longer available in the RRF files.  


## RxNav RxClass  

### Features  

* Added option to point to a prior RxClass RxNav version 
with a `prior_version` argument. This allows to test out development 
using extracted data when a new version is available via that API and having 
to rerun all the API calls.  

* Added CONCEPT_SYNONYM table    


### Bugs  

* Fixed DDL to match new format  

* `NA` concept codes are filtered out of the CONCEPT table after 
confirming that they are duplicates, but the root cause of this error 
still needs to be investigated.  


# setupRxNorm 1.4.0  

* Added RxClass Data v12 in new format  

# setupRxNorm 1.3.0  

* Added RxClass Data v11 
* Updated RxClass CONCEPT table output to include concept_class_id  

# setupRxNorm 1.2.0  

* Added feature that converts RxClass API responses into relational database format  



