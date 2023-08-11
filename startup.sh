#!/bin/sh

IOE_DIR=$1
START_TIME_FILE=/tmp/ioe_start_time.txt
STARTUP_LOG=/tmp/ioe_startup.log

cd $IOE_DIR

date > $START_TIME_FILE
date +%s >> $START_TIME_FILE

echo "Starting...." > $STARTUP_LOG
date +"Start Time: %c" >> $STARTUP_LOG

if [ -f $IOE_DIR/ipt/strip_mode ]
then
	i=1
	while [ $i -le 300 ]
	do
		if [ -f $IOE_DIR/ipt/strip_done ]
		then
			if [ $i -gt 1 ]
			then
				sync
			fi
			break
		fi
		sleep 1
		let i++
	done
fi

if [ -f $IOE_DIR/ipt/startup.sh ]
then
	sh $IOE_DIR/ipt/startup.sh
fi

if [ -f $IOE_DIR/ipt/upgrade ]
then
	echo "Upgrade Script detected! Upgrade ioe system!" >> $STARTUP_LOG
	sh $IOE_DIR/ipt/upgrade.sh
	if [ $? -eq 0 ]
		rm -f $IOE_DIR/ipt/upgrade
	then
		echo "Failed to run upgrage script" >> $STARTUP_LOG
		exit $?
	fi
else
	echo "NO upgrade needed!" >> $STARTUP_LOG
fi

if [ -f $IOE_DIR/ipt/rollback ]
then
	echo "RollBack Script detected! Roll back ioe system!" >> $STARTUP_LOG
	sh $IOE_DIR/ipt/rollback.sh
	if [ $? -eq 0 ]
		rm -f $IOE_DIR/ipt/rollback
	then
		echo "Failed to run rollback script" >> $STARTUP_LOG
		exit $?
	fi
else
	echo "NO rollback needed!" >> $STARTUP_LOG
fi

if [ -f $IOE_DIR/.env ]
then
	set -o allexport; source $IOE_DIR/.env; set +o allexport
fi

sync &

echo "Startup Script Done!" >> $STARTUP_LOG
