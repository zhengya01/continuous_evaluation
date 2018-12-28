#!/usr/bin/env python
XONSH_SHOW_TRACEBACK = True
XONSH_SHOW_TRACEBACK = True

import sys; sys.path.insert(0, '')
import config
from config import pjoin
from utils import PathRecover, log
import persistence as pst
import os
import repo
import argparse
import traceback
import time
import shutil
import subprocess

ceroot=config.workspace
os.environ['ceroot'] = config.workspace
mode = os.environ.get('mode', 'evaluation')
specific_tasks = os.environ.get('specific_tasks', None)
specific_tasks = specific_tasks.split(',') if specific_tasks else []
case_type = os.environ.get('case_type', None)


def parse_args():
    parser= argparse.ArgumentParser("Tool for running CE models")
    parser.add_argument(
        '--modified',
        action='store_true',
        help='if set, we will just run modified models.')
    args = parser.parse_args()
    return args

def main():
    #try_start_mongod()
    args = parse_args()
    if (not args.modified) and (not specific_tasks) and (not case_type):
        refresh_baseline_workspace()

    suc, exception_task = evaluate_tasks(args)
    if suc:
        display_success_info()
        sys.exit(0)
    else:
        if (not args.modified) and (not specific_tasks):
            display_fail_info(exception_task)
        sys.exit(-1)


def update_baseline():
    ''' update the baseline in a git repo using current base. '''
    log.warn('updating baseline')
    commit = repo.get_commit(config.paddle_path)
    with PathRecover():
        message = "evalute [%s]" % commit
        for task_name in get_tasks():
            task_dir = pjoin(config.baseline_path, task_name)
            os.chdir(task_dir)
            log.info('task_dir', task_dir)
            if os.path.isdir('latest_kpis'):
                # update baseline if the latest kpi is better than history
                tracking_kpis = get_kpi_tasks(task_name)

                for kpi in tracking_kpis:
                    # if the kpi is not actived, do not update baseline.
                    if not kpi.actived: continue
                    kpi.root = task_dir
                    better_ratio = kpi.compare_with(kpi.cur_data, kpi.baseline_data)
                    if  better_ratio > config.kpi_update_threshold:
                        log.warn('current kpi %s better than history by %f, update baseline' % (kpi.out_file, better_ratio))
                        shutil.copyfile(kpi.out_file, kpi.his_file)


        os.chdir(config.baseline_path)
        os.system('pwd')
        os.system('git diff')
        cmd = "git diff"
        status = subprocess.check_output(cmd, shell=True)
        if status:
            log.warn('update github baseline')
            '''
            due to the selected update controled by `config.kpi_update_threshold`, if one task passed, there might be no baselines to update.
            '''
            cmd = 'git pull origin master; git commit -a -m "%s"; git push' % message
            os.system(cmd)
        else:
            log.warn('no baseline need to update')


def refresh_baseline_workspace():
    ''' download baseline. '''
    if mode != "baseline_test":
        # ssh from home is not very stable, can be solved by retry.
        max_retry = 10
        for cnt in range(max_retry):
            try:
                if os.path.exists(config.baseline_path):
                    shutil.rmtree(config.baseline_path)
                cmd = "git clone %s %s" % (config.baseline_repo_url, config.baseline_path)
                log.info("cmd", cmd)
                tp = os.system(cmd)
                log.info("gitclone", tp)
                log.info("git clone %s suc" % config.baseline_repo_url)
                break
            except Exception as e:
                if cnt == max_retry - 1:
                    raise Exception("git clone failed %s " % e)
                else:
                    log.warn('git clone failed %d, %s' % (cnt, e))
                    time.sleep(3)


def evaluate_tasks(args):
    '''
    Evaluate all the tasks. It will continue to run all the tasks even
    if any task is failed to get a summary.
    '''
    os.chdir(config.workspace)
    paddle_commit = repo.get_commit(config.paddle_path)
    commit_time = repo.get_commit_date(config.paddle_path)
    log.warn('commit', paddle_commit)
    all_passed = True
    exception_task = {}
    
    if specific_tasks:
        tasks = specific_tasks
        log.warn('run specific tasks', tasks)
    elif args.modified:
        tasks = [v for v in get_changed_tasks()]
        log.warn('run changed tasks', tasks)
    else:
        tasks = [v for v in get_tasks()]
        log.warn('run all tasks', tasks)
        
    log.info("tasks", tasks)
    for task in tasks:
        try:
            log.info("befor run task")
            passed, eval_infos, kpis, kpi_values, kpi_types = evaluate(task)
            log.info("after run task", passed)

            if mode != "baseline_test":
                log.warn('add evaluation %s result to mongodb' % task)
                kpi_objs = get_kpi_tasks(task)
                if (not args.modified) and (not specific_tasks):
                    log.info("befor update record")
                    pst.add_evaluation_record(commitid = paddle_commit,
                                              date = commit_time,
                                              task = task,
                                              passed = passed,
                                              infos = eval_infos,
                                              kpis = kpis,
                                              kpi_values = kpi_values,
                                              kpi_types = kpi_types,
                                              kpi_objs = kpi_objs)
                    log.info("after update record")
                log.warn('after add evaluation %s result to mongodb' % task)
            if not passed:
                all_passed = False
        except Exception as e:
            exception_task[task] = traceback.format_exc()
            all_passed = False

    return all_passed, exception_task


def evaluate(task_name):
    '''
    task_name: str
        name of a task directory.
    returns:
        passed: bool
            whether this task passes the evaluation.
        eval_infos: list of str
            human-readable evaluations result for all the kpis of this task.
        kpis: dict of (kpi_name, list_of_float)
    '''
    task_dir = pjoin(config.baseline_path, task_name)
    log.warn('evaluating model', task_name)

    with PathRecover():
        try:
            os.chdir(task_dir)
            log.info("befor ./run.xsh")
            cmd = "./run.xsh"
            log.info("after ./run.xsh")
            os.system(cmd)
        except Exception as e:
            print(e)

        log.info("befor get_kpi_tasks")
        tracking_kpis = get_kpi_tasks(task_name)
        log.info("after get_kpi_tasks")

        # evaluate all the kpis
        eval_infos = []
        kpis = []
        kpi_values = []
        kpi_types = []
        passed = True
        log.info("befor check kpi")
        for kpi in tracking_kpis:
            suc = kpi.evaluate(task_dir)
            if (not suc) and kpi.actived:
                ''' Only if the kpi is actived, its evaluation result would affect the overall tasks's result. '''
                passed = False
                log.info("Task [%s] failed!" % task_name)
                log.info("details:", kpi.fail_info)
            kpis.append(kpi.name)
            kpi_values.append(kpi.cur_data)
            kpi_types.append(kpi.__class__.__name__)
            # if failed, still continue to evaluate the other kpis to get full statistics.
            eval_infos.append(kpi.fail_info if not suc else kpi.success_info)
        log.info("after check kpi")
        log.info("evaluation kpi info: %s %s %s" % (passed, eval_infos, kpis))
        return passed, eval_infos, kpis, kpi_values, kpi_types


def get_tasks():
    with PathRecover():
        os.chdir(config.workspace)
        subdirs = os.listdir(config.baseline_path)
            
        log.info("subdirs", subdirs)
        if case_type:
            return filter(lambda x : x.startswith('%s_' % case_type), subdirs)
        else:
            return filter(lambda x : not (x.startswith('__') or x.startswith('model_')
                   or x.endswith('.md') or x.startswith('.')), subdirs)


def display_fail_info(exception_task):
    paddle_commit = repo.get_commit(config.paddle_path)
    infos = pst.db.finds(config.table_name, {'commitid': paddle_commit, 'type': 'kpi' })
    log.info('Evaluate [%s] failed!' % paddle_commit)
    log.warn('The details:')
    detail_info = ''
    for info in infos:
        if not info['passed']:
            log.warn('task:', info['task'])
            detail_info += info['task'] + ' '
            log.warn('passed: ', info['passed'])
            log.warn('infos', '\n'.join(info['infos']))
            log.warn('kpis keys', info['kpis-keys'])
            log.warn('kpis values', info['kpis-values'])
    if exception_task:
        for task, info in exception_task.items():
            detail_info += task + ' '
            log.info("%s %s" %(task, info))
    with open("fail_models", 'w') as f:
        f.write(detail_info)


def display_success_info():
    paddle_commit = repo.get_commit(config.paddle_path)
    log.warn('Evaluate [%s] successed!' % paddle_commit)


def try_start_mongod():
    cmd = "ps ax | grep mongod"
    output = subprocess.check_output(cmd, shell=True)
    output = output.decode()
    out = output.strip().split('\n')
    log.info('out', out)
    if len(out) < 1: # there are no mongod service
        log.warn('starting mongodb')
        os.makedirs(r"/chunwei/ce_mongo.db")
        cmd = "mongod --dbpath /chunwei/ce_mongo.db &"
        os.system(cmd)


def get_kpi_tasks(task_name):
    with PathRecover():
        os.chdir(config.workspace)
        env = {}
        try:
            log.info("task_name", task_name)
            log.info('from tasks.%s.continuous_evaluation import tracking_kpis'
                % task_name, env)
            exec('from tasks.%s.continuous_evaluation import tracking_kpis'
                % task_name, env)
            log.info("import from continuous_evaluation suc.")
        except Exception as e: 
            exec('from tasks.%s._ce import tracking_kpis'
                % task_name, env)
        
        tracking_kpis = env['tracking_kpis']
        log.info("tracking_kpis", tracking_kpis)
        return tracking_kpis


def get_changed_tasks():
    tasks = []
    os.chdir(config.baseline_path)
    cmd = 'git diff master | grep "diff --git"'
    out = subprocess.check_output(cmd, shell=True)
    out = out.decode()
    out = out.strip()
    for item in out.split('\n'):
        try:
            task = item.split()[3].split('/')[1]
            if task not in tasks:
                tasks.append(task)
        except:
            continue
    log.warn("changed tasks: %s" % tasks)
    return tasks

main()