test_run = require('test_run').new()
REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }

test_run:create_cluster(REPLICASET_1, 'router')
test_run:create_cluster(REPLICASET_2, 'router')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')

test_run:cmd('create server router_1 with script="router/router_1.lua"')
test_run:cmd('start server router_1')
test_run:switch('storage_1_a')
cfg.collect_bucket_garbage_interval = 100
vshard.storage.cfg(cfg, names.storage_1_a)
vshard.storage.rebalancer_disable()
for i = 1, 100 do box.space._bucket:replace{i, vshard.consts.BUCKET.ACTIVE} end

test_run:switch('storage_2_a')
cfg.collect_bucket_garbage_interval = 100
vshard.storage.cfg(cfg, names.storage_2_a)
vshard.storage.rebalancer_disable()
for i = 101, 200 do box.space._bucket:replace{i, vshard.consts.BUCKET.ACTIVE} end

test_run:switch('router_1')
vshard.router.bucket_discovery(100) ~= nil

test_run:switch('storage_1_a')
box.space._bucket:update({100}, {{'=', 2, vshard.consts.BUCKET.SENT}, {'=', 3, replicasets[2]}})

test_run:switch('storage_2_a')
box.space._bucket:replace{100, vshard.consts.BUCKET.ACTIVE}
customer_add({customer_id = 1, bucket_id = 100, name = 'name', accounts = {}})

test_run:switch('router_1')
vshard.router.call(100, 'read', 'customer_lookup', {1}, {timeout = 100})

vshard.router.static.route_map[100] = vshard.router.static.replicasets[replicasets[1]]
vshard.router.call(100, 'write', 'customer_add', {{customer_id = 2, bucket_id = 100, name = 'name2', accounts = {}}}, {timeout = 100})

-- Create cycle.
test_run:switch('storage_2_a')
box.space._bucket:update({100}, {{'=', 2, vshard.consts.BUCKET.SENT}, {'=', 3, replicasets[1]}})

test_run:switch('router_1')
_ = vshard.router.call(100, 'read', 'customer_lookup', {1}, {timeout = 1})

-- Wait reconfiguration durigin timeout, if a replicaset was not
-- found by bucket.destination from WRONG_BUCKET or
-- TRANSFER_IS_IN_PROGRESS error object.
test_run:switch('storage_2_a')
box.space._bucket:replace({100, vshard.consts.BUCKET.ACTIVE})
test_run:switch('storage_1_a')
box.space._bucket:replace({100, vshard.consts.BUCKET.SENT, replicasets[2]})
test_run:switch('router_1')
-- Emulate a situation, when a replicaset_2 while is unknown for
-- router, but is already known for storages.
save_rs2 = vshard.router.static.replicasets[replicasets[2]]
vshard.router.static.replicasets[replicasets[2]] = nil
vshard.router.static.route_map[100] = vshard.router.static.replicasets[replicasets[1]]

fiber = require('fiber')
call_retval = nil
err = nil
test_run:cmd("setopt delimiter ';'")
function do_call(timeout)
    call_retval, err =
        vshard.router.call(100, 'write', 'customer_add',
                           {{customer_id = 3, bucket_id = 100, name = 'name3',
                             accounts = {}}}, {timeout = timeout})
end;
test_run:cmd("setopt delimiter ''");
--
-- Background call starts 'write' request, but can not find a
-- replicaset by UUID. It must fail by timeout.
--
f = fiber.create(do_call, 1)
while not err do fiber.sleep(0.1) end
test_run:grep_log('router_1', 'please update configuration')
err

--
-- Now try again, but update configuration during call(). It must
-- detect it and end with ok.
--
require('log').info(string.rep('a', 1000))
vshard.router.static.route_map[100] = vshard.router.static.replicasets[replicasets[1]]
call_retval = nil
f = fiber.create(do_call, 100)
while not test_run:grep_log('router_1', 'please update configuration', 1000) do fiber.sleep(0.1) end
vshard.router.static.replicasets[replicasets[2]] = save_rs2
while not call_retval do fiber.sleep(0.1) end
call_retval
vshard.router.call(100, 'read', 'customer_lookup', {3}, {timeout = 1})

test_run:cmd("switch default")
test_run:cmd('stop server router_1')
test_run:cmd('cleanup server router_1')
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
