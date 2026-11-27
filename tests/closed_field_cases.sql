-- Controlled source feed: January synthetic bank issue; original current February–April.
CREATE SCHEMA module1;
CREATE TABLE module1.metro2_account_blueprint(account integer PRIMARY KEY, history text);
INSERT INTO module1.metro2_account_blueprint VALUES (1,'1000123L'),(2,'100012'),(3,'1000123J'),(4,'1000123G'),(5,'1000123K'),(6,'1000123H');
CREATE TABLE module1.metro2_status_history AS
SELECT account, (DATE '2020-01-01' + make_interval(months=>ofs-1))::date byte_date,ofs perf_age,substring(history,ofs,1) status
FROM module1.metro2_account_blueprint CROSS JOIN LATERAL generate_series(1,length(history)) AS ofs;
CREATE TABLE module1.metro2_final AS
SELECT account,'FIXTURE'::text AS profile_type, (DATE '2020-01-01'+make_interval(months=>length(history)))::date latest_doai,
(DATE '2020-01-01'+make_interval(months=>length(history)))::date date_closed,reverse(history) full_php,
(DATE '2020-01-01'+make_interval(months=>length(history)-1))::date php_left_byte_date,DATE '2020-01-01' php_right_byte_date,
CASE account WHEN 1 THEN '64' WHEN 2 THEN '13' WHEN 3 THEN '61' WHEN 4 THEN '62' WHEN 5 THEN '63' WHEN 6 THEN '65' END account_status_17a,
CASE WHEN account=2 THEN '2' END AS payment_rating_17b,DATE '2020-05-01' date_of_first_delinquency FROM module1.metro2_account_blueprint;
