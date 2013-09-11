#!/bin/bash

# config
username="Administrator"
password="1ncharge"
event_id=""
oxifeed_url=""
database="willhill_dev@db01_1170"
start_delay="120"
cashout_price=""
log_xml="1"
ignore_updates=0

# statics for assertion
PRICE=1
NULL=2
BAD=3
CAY=4
CAN=5

# how long to wait between messages (seconds)
# how long in the future should the event be (seconds)
xml_dir="xml"

print_usage() {
	echo " "
	echo "Usage: $0 [-up] [oxifeed_url]"
	echo "  -u : admin username, default esaunder"
	echo "  -p : admin password, default esander01"
	echo "  -d : database, default willhill_dev@db01_1170"
	echo "  -i : server is ignoring CIMB updates, default 0"
	echo " "
	echo "Example: $0 -uAdmininstrator -p1ncharge -dopenbet -i https://titan.orbis/oxifeed_test"
	echo " "
}

# read options in from the command line
while getopts ":u:p:d:i" o;
do
	case $o in
		u)  username=$OPTARG;;
		p)  password=$OPTARG;;
	    d)  database=$OPTARG;;
		i)  ignore_updates=1;;
		/?)
			print_usage;
			exit 1;;
	esac
done

# grab the ev_id and url from standard args
eval "oxifeed_url=\$$OPTIND"

# sanity
if [ "$oxifeed_url" = "" ]
then
	print_usage;
	exit;
fi


# set some other conf variables based on the config above
gen_config() {

	# prefix of the incident id
	external_id=`date +%s%N | cut -b1-13`

	# set the start time in our event to the configured value
	start_time=`date --date "now $start_delay seconds" '+%Y-%m-%d %H:%M:%S'`

	if [ `date +"%Z"` = "BST" ]
	then
		offset="+01:00"
	fi
}


# search and replace the xml according to the config
set_xml() {

	sed -i "s/password=\"[a-zA-Z0-9]*\"/password=\"$password\"/g" xml/*.xml
	sed -i "s/username=\"[a-zA-Z0-9]*\"/username=\"$username\"/g" xml/*.xml
	sed -i "s/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}/$start_time/g" xml/setup.xml
	sed -i "s/-[0-9]*<\/externalId/-$external_id\<\/externalId/g" xml/*.xml
}


# curl an xml file at the configured url (filename passed as arg0)
# -1: xml file
send_xml() {

	file=$1

	if [ "$log_xml" != "" ]
	then
		echo " "
		echo "|======================== send_xml ========================|"
		echo " "
		echo "sending $xml_dir/$file to $oxifeed_url"
		echo " "

		cat $xml_dir/$file
		outcom="| tee xml/tmp_resp.xml"

		echo " "
		echo "----------------------------------------------------------------"
		echo " "
		curl -d "@$xml_dir/$file" --insecure --header "Content-Type: text/xml; charset=utf-8" $oxifeed_url 2> /dev/null | tee xml/tmp_resp.xml

	else
		curl -d "@$xml_dir/$file" --insecure --header "Content-Type: text/xml; charset=utf-8" $oxifeed_url 2> /dev/null > xml/tmp_resp.xml
	fi


	if [ "$log_xml" != "" ]
	then
		echo " "
		echo "|==========================================================|"
		echo " "
	fi
}


# type
# ev_oc_id
get_price() {

	type=$1
	ev_oc_id=$2
	price=`echo "select NVL(${type}_num,-1), NVL(${type}_den,-1) from tevoc where ev_oc_id = $ev_oc_id" | dbaccess $database 2> /dev/null | egrep "[1-9]" | awk '{print $1"/"$2}'`
}


# type
# ev_oc_id
get_cashout_avail() {

	ev_mkt_id=$1
	cashout_avail=`echo "select cashout_avail from tevmkt where ev_mkt_id = $ev_mkt_id" | dbaccess $database 2> /dev/null | egrep "[YN]"`
}


# there's no way of nulling the live price with the feed. have to hack it
# - 1: ev_oc_id
clear_lp() {

	ev_oc_id=$1
	garc=`echo "update tEvOc set lp_num = '', lp_den = '' where ev_oc_id = $ev_oc_id" | dbaccess $database 2> /dev/null`
}


# there's no way of nulling the live price with the feed. have to hack it
# - 1: ev_mkt_id
# - 2: value to set it to
set_cashout_avail() {

	ev_mkt_id=$1
	garc=`echo "update tEvMkt set cashout_avail = '$2' where ev_mkt_id = $ev_mkt_id" | dbaccess $database 2> /dev/null`
}


# wrapper
set_cay() {
	set_cashout_avail $1 "Y"
}


# wrapper
set_can() {
	set_cashout_avail $1 "N"
}


# get openbet ids from response xml
# - 1: (event|market|selection)
# - 2: (Insert|Update)
get_ids() {

	# We go through and replace all the 152s with BAD status for test eval
	sed_str="/code=\"\(152\|453\)\"/c<${1}Id>\n<openbetId>BAD</openbetId>"
	ids=(`grep -A4 "<${1}${2}>" xml/tmp_resp.xml | sed ${sed_str} | grep -A1 "<${1}Id>" | grep openbetId | awk -F ">" '{print $2}' | awk -F "<" '{print $1}'`)
}


# insert a new event and market we can use to test, set the id's we've created to globals for use later
setup_event() {

	echo " "
	echo "Setting up event $event_id"

	send_xml setup.xml

	get_ids event Insert
	event_ids=(${ids[@]})
	get_ids market Insert
	market_ids=(${ids[@]})

	echo "Set up event_id: ${event_ids[@]} with markets: ${market_ids[@]}"
	echo " "
}


# Perform a simple check and log success / failure
# - 1 == 2
# - name of test
simple_assert() {

	if [ "$1" != "$2" ]
	then
		echo -e "\e[00;31mFAIL\e[00m: $3 - expecting $1 got $2"
	else
		echo -e "\e[00;32mPASS\e[00m: $3"
	fi
}


# Check a selection in the database
#
# - 1 assertion type (PRICE/NULL/BAD)
# - 2 id
# - 3 test case desc
db_assert() {

	if [ "$1" == "" -o "$2" == "" -o "$3" == "" ]
	then
		echo -e "\e[00;31mFAIL\e[00m: No data supplied, invalid response?"
	else
		# check for bad responses first as we cant look these up
		# note we're checking to the string BAD here not $BAD
		if [ "$1" == "$BAD" ]
		then
			if [ "$2" == "BAD" ]
			then
				echo -e "\e[00;32mPASS\e[00m: $3"
			else
				# we've got something in the ID, find out what the price is for infos
				get_price "cp" $2
				echo -e "\e[00;31mFAIL\e[00m: $3 - expecting BAD got $price"
			fi
		else

			# if we've got BAD back instead of an ID, its a fail
			if [ "$2" == "BAD" ]
			then
				if [ "$1" == "PRICE" ]
				then
					echo -e "\e[00;31mFAIL\e[00m: $3 - expecting PRICE got BAD"
				else
					echo -e "\e[00;31mFAIL\e[00m: $3 - expecting NULL got BAD"
				fi
			elif [ "$1" == "$NULL" ]
			then
				# we're looking for a price comparison in the db
				get_price "cp" $2

				# we get null back as -1 from the db
				if [ "$price" == "-1/-1" ]
				then
					echo -e "\e[00;32mPASS\e[00m: $3 (id: $2) "
				else
					echo -e "\e[00;31mFAIL\e[00m: $3 (id: $2) - expecting NULL got $price"
				fi
			elif [ "$1" == "$PRICE" ]
			then
				# we're looking for a price comparison in the db
				get_price "cp" $2

				if [ "$price" != "-1/-1" ]
				then
					echo -e "\e[00;32mPASS\e[00m: $3 (id: $2)  "
				else
					echo -e "\e[00;31mFAIL\e[00m: $3 (id: $2) - expecting PRICE got $price"
				fi
			elif [ "$1" == "$CAY" ]
			then
				get_cashout_avail $2

				if [ "$cashout_avail" == "Y" ]
				then
					echo -e "\e[00;32mPASS\e[00m: $3 (id: $2)  "
				else
					echo -e "\e[00;31mFAIL\e[00m: $3 (id: $2) - expecting Y got $cashout_avail"
				fi
			elif [ "$1" == "$CAN" ]
			then
				get_cashout_avail $2

				if [ "$cashout_avail" == "N" ]
				then
					echo -e "\e[00;32mPASS\e[00m: $3 (id: $2)  "
				else
					echo -e "\e[00;31mFAIL\e[00m: $3 (id: $2) - expecting N got $cashout_avail"
				fi
			fi
		fi
	fi
}


array_assert(){

	a=$1[@]
	r=$2[@]
	asserts=("${!a}")
	results=("${!r}")

	for ((i = 0; i < "${#asserts[@]}"; i++))
	do
		desc=`echo ${asserts[$i]} | awk -F "|" '{print $1}'`
		expect=`echo ${asserts[$i]} | awk -F "|" '{print $2}'`
		post_proc=`echo ${asserts[$i]} | awk -F "|" '{print $3}'`

		db_assert $expect ${results[$i]} "$desc"

		# have we got any postprocessing to do?
		if [ "$post_proc" != "" ]
		then
			$post_proc ${results[$i]}
		fi

	done
}


setup_insert_asserts() {

	num_insert_seln="24"
	num_insert_market="4"

	insert_total=`expr $num_insert_seln + $num_insert_market`

	# array structure per item (test_desc|assertion|post process func)
	insert_seln_asserts=(\
		"#3 Calculate with null cashout price|$PRICE" \
		"#4 caclulate with rubbish cashout price|$BAD" \
		"#5 valid decimal|$PRICE" \
		"#6 invalid decimal (fraction)|$BAD" \
		"#7 null decimal|$NULL" \
		"#8 valid fractional|$PRICE" \
		"#9 invalid fraction (decimal)|$BAD" \
		"#10 null fractional|$NULL" \
		"#11 not supplied|$PRICE" \
		"#12 rubbish cashout price type|$BAD" \
		"#13 Calculate with null cashout price|$PRICE" \
		"#14 caclulate with rubbish cashout price|$BAD" \
		"#15 valid decimal|$PRICE" \
		"#16 invalid decimal (fraction)|$BAD" \
		"#17 null decimal|$NULL" \
		"#18 valid fractional|$PRICE" \
		"#19 invalid fraction (decimal)|$BAD" \
		"#20 null fractional|$NULL|clear_lp" \
		"#21 not supplied|$NULL|clear_lp" \
		"#22 rubbish cashout price type|$BAD" \
		"#23 no LP valid fractional/decimal|$BAD" \
		"#24 no LP valid calculate|$BAD" \
		"#25 no LP valid null fractional/decimal (note use of b91)|$BAD" \
		"#N/A need another good insert for the updates (note use of b91)|$PRICE|clear_lp" \
	)

	insert_mkt_asserts=(\
		"#26 Market with invalid cashout_avail|$BAD" \
		"#61 Market with cashout_avail Y|$CAY|set_can" \
		"#62 Market with cashout_avail N|$CAN|set_cay" \
		"#63 Market with cashout_avail not supplied|$CAN|set_cay" \
	)

	# sanity check
	if [ "${#insert_seln_asserts[@]}" != "$num_insert_seln" ]
	then
		echo "setup_insert_asserts: Invalid setup (seln) - ${#insert_seln_asserts[@]} assertions"
		exit 1
	fi

	if [ "${#insert_mkt_asserts[@]}" != "$num_insert_market" ]
	then
		echo "setup_insert_asserts: Invalid setup (market)- ${#insert_mkt_asserts[@]} assertions"
		exit 1
	fi
}


insert_asserts() {

	# have we had the correct number of responses?
	simple_assert $insert_total $insert_test_total "NUM INSERT RESPONSES"

	array_assert insert_seln_asserts selection_ids
	array_assert insert_mkt_asserts market_ids
}


insert_test() {

	setup_insert_asserts

	# test insert cases
	send_xml insert.xml

	get_ids selection Insert
	selection_ids=(${ids[@]})

	get_ids market Insert
	market_ids=(${ids[@]})

	echo "Insert test finished with:"
	echo "EVMKT: ${#market_ids[@]} ev_mkt_ids: ${market_ids[@]}"
	echo "EVOC:  ${#selection_ids[@]} ev_oc_ids: ${selection_ids[@]}"

	insert_test_total=`expr ${#market_ids[@]} +  ${#selection_ids[@]}`

	echo ""
	echo "|=======================|INSERT SUMMARY|=======================|"
	insert_asserts
	echo "|==============================================================|"
	echo ""
}


# For these tests to pass the app should be configured to listen for CIMB updates
setup_update_asserts() {

	num_update_seln="13"
	num_update_market="3"

	update_total=`expr $num_update_seln + $num_update_market`

	# array structure per item (test_desc|assertion|post process func)
	update_seln_asserts=(\
		"#31 Calculate with null cashout price|$PRICE"
		"#32 Calculate with rubbish cashout price|$BAD"
		"#33 Valid decimal|$PRICE"
		"#34 invalid decimal (fraction)|$BAD"
		"#35 null decimal|$NULL"
		"#36 Valid fraction|$PRICE"
		"#37 invalid fraction (decimal)|$BAD"
		"#38 null fraction|$NULL"
		"#39 not supplied|$NULL"
		"#40 rubbish cashout price type|$BAD"
		"#41 no LP valid fractional/decimal|$NULL"
		"#42 no LP valid calculate|$NULL"
		"#43 no LP null fractional/decimal|$NULL"
	)

	update_mkt_asserts=(\
		"#68 cashout avail Y|$CAY|set_can"
		"#69 cashout avail N|$CAN|set_cay"
		"#70 cashout avail NS|$CAY"
	)

	# sanity check
	if [ "${#update_seln_asserts[@]}" != "$num_update_seln" ]
	then
		echo "setup_update_asserts: Invalid setup (seln) - ${#update_seln_asserts[@]} assertions"
		exit 1
	fi

	if [ "${#update_mkt_asserts[@]}" != "$num_update_market" ]
	then
		echo "setup_update_asserts: Invalid setup (market)- ${#update_mkt_asserts[@]} assertions"
		exit 1
	fi
}


# For these tests to pass the app should be configured to ignore CIMB updates
setup_update_ignore_asserts() {

	num_update_seln="13"
	num_update_market="3"

	update_total=`expr $num_update_seln + $num_update_market`

	# array structure per item (test_desc|assertion|post process func)
	update_seln_asserts=(\
		"#44 Calculate with null cashout price|$PRICE"
		"#45 Calculate with rubbish cashout price|$PRICE"
		"#46 Valid decimal|$NULL"
		"#47 invalid decimal (fraction)|$PRICE"
		"#48 null decimal|$NULL"
		"#49 Valid fraction|$PRICE"
		"#50 invalid fraction (decimal)|$PRICE"
		"#51 null fraction|$PRICE"
		"#52 not supplied|$NULL"
		"#53 rubbish cashout price type|$PRICE"
		"#54 no LP valid fractional/decimal|$NULL"
		"#55 no LP valid calculate|$NULL"
		"#56 no LP null fractional/decimal|$NULL"
	)

	update_mkt_asserts=(\
		"#71 cashout avail Y|$CAN"
		"#72 cashout avail N|$CAY"
		"#73 cashout avail NS|$CAY"
	)

	# sanity check
	if [ "${#update_seln_asserts[@]}" != "$num_update_seln" ]
	then
		echo "setup_update_asserts: Invalid setup (seln) - ${#update_seln_asserts[@]} assertions"
		exit 1
	fi

	if [ "${#update_mkt_asserts[@]}" != "$num_update_market" ]
	then
		echo "setup_update_asserts: Invalid setup (market)- ${#update_mkt_asserts[@]} assertions"
		exit 1
	fi

}


# - 1 array of selection ids we got from the inserts
# - 2 array of market ids we got from the inserts
# - 3 how many seln_ids do we need (from setup_update_asserts)
# - 4 how many mkt_ids do we need
set_update_xml() {


	o=$1[@]
	m=$2[@]

	all_seln_ids=("${!o}")
	all_mkt_ids+=("${!m}")

	good_seln_ids=()
	good_mkt_ids=()

	# strip all the BADs out
	for id in "${all_seln_ids[@]}"
	do
		if [ "$id" != "BAD" ]
		then
			good_seln_ids+=($id)
		fi
	done

	# strip all the BADs out
	for id in "${all_mkt_ids[@]}"
	do
		if [ "$id" != "BAD" ]
		then
			good_mkt_ids+=($id)
		fi
	done

	# sanity that we've enough seln
	if [[ ${#good_seln_ids[@]} -lt $3 ]]
	then
		echo "Not enough good seln inserts to perform update test (${#good_seln_ids[@]} : $3)"
		exit 1
	fi

	# sanity that we've enough mkt
	if [[ ${#good_mkt_ids[@]} -lt $4 ]]
	then
		echo "Not enough good mkt inserts to perform update test (${#good_mkt_ids[@]} : $4)"
		exit 1
	fi

	## SED SELN
	units=("ph31" "ph32" "ph33" "ph34" "ph35" "ph36" "ph37" "ph38" "ph39" "ph40" "ph41" "ph42" "ph43")

	i=0

	# give a different ev_oc_id to each test case, in order, so we can assert aferwards
	# TODO- we may need to overwrite the NO LP ones separately, but let's get it going first
	for unit in ${units[@]}
	do
		`sed -i "s/<\!-- $unit -->[0-9]*/<\!-- $unit -->${good_seln_ids[$i]}/g" xml/update*.xml`
		let i++
	done

	## SED MKT
	units=("ph68" "ph69" "ph70")

	i=0

	# give a different ev_oc_id to each test case, in order, so we can assert aferwards
	# TODO- we may need to overwrite the NO LP ones separately, but let's get it going first
	for unit in ${units[@]}
	do
		`sed -i "s/<\!-- $unit -->[0-9]*/<\!-- $unit -->${good_mkt_ids[$i]}/g" xml/update*.xml`
		let i++
	done

}


update_asserts() {

	# have we had the correct number of responses?
	simple_assert $update_total $update_test_total "NUM UPDATE RESPONSES"

	array_assert update_seln_asserts selection_ids
	array_assert update_mkt_asserts market_ids

}


update_test() {

	# we need to switch the assertions if running in ignore mode
	if [ "$ignore_updates" == "1" ]
	then
		setup_update_ignore_asserts
	else
		setup_update_asserts
	fi

	set_update_xml selection_ids market_ids $num_update_seln $num_update_market

	# test update cases
	send_xml update.xml

	get_ids selection Update
	selection_ids=(${ids[@]})

	get_ids market Update
	market_ids=(${ids[@]})

	echo "Update test finished with:"
	echo "EVMKT: ${#market_ids[@]} ev_mkt_ids: ${market_ids[@]}"
	echo "EVOC:  ${#selection_ids[@]} ev_oc_ids: ${selection_ids[@]}"

	update_test_total=`expr ${#selection_ids[@]} + ${#market_ids[@]}`

	echo ""
	echo "|=======================|UPDATE SUMMARY|=======================|"
	update_asserts
	echo "|==============================================================|"
	echo ""

	# test update cases
	send_xml update_price.xml

	get_ids selection Update
	selection_ids=(${ids[@]})

	echo "Update price test finished with:"
	echo "EVMKT: ${#market_ids[@]} ev_mkt_ids: ${market_ids[@]}"
	echo "EVOC:  ${#selection_ids[@]} ev_oc_ids: ${selection_ids[@]}"

	update_test_total=`expr ${#selection_ids[@]} + ${#market_ids[@]}`

	echo ""
	echo "|====================|UPDATE PRICE SUMMARY|====================|"
	update_asserts
	echo "|==============================================================|"
	echo ""

}

gen_config
set_xml
setup_event
insert_test
update_test
