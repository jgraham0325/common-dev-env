#Avoids DB2 SQL error: SQLCODE: -973, SQLSTATE: 57011, SQLERRMC: PCKCACHESZ
~/sqllib/bin/db2 connect to GSYNCDB && ~/sqllib/bin/db2 update db cfg for GSYNCDB using PCKCACHESZ 78525
