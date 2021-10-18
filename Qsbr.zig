const std = @import("std");
const TailQueue = std.TailQueue;
const print = std.debug.print;
const expect = std.testing.expect;



threadlocal var qsbr_local = Qsbr.QsbrNode{.data=1};
fn getState(self: *Qsbr) *Qsbr.QsbrNode {
    return &qsbr_local;
}


pub const Qsbr = struct {
    pub const Queue = TailQueue(EpochType);
    pub const QsbrNode = Queue.Node;
    const Self = @This();
    pub const EpochType = usize;
    
    queue: Queue =  Queue{},
    mutex: std.Mutex = std.Mutex{},
    epoch: EpochType = 1,
    
    getStateFn: fn(qsbr: *Qsbr) *QsbrNode = getState,
    pub fn getLocalState(self: *Self) *QsbrNode {
        return self.getStateFn(self);
    }
    
    pub fn init(getstatefunc: ?fn(self: *Qsbr) *QsbrNode) Self {
        if(getstatefunc) |f|{
            return Self{.getStateFn=f};
        } else {
            return Self{};
        }
    }
    
    pub fn deinit(self: *Self) void {
    }
    
    pub fn register(self: *Self) void {
        const lock = self.mutex.acquire();
        defer lock.release();
        
        self.queue.append(self.getLocalState());
    }
    
    pub fn unregister(self: *Self) void {
        const lock = self.mutex.acquire();
        defer lock.release();
        var node = self.getLocalState();
        self.queue.remove(node);
        node.next = null;
        node.prev = null;
    }
    
    pub fn quiescent(self: *Self) void {
        @fence(.SeqCst);
        const state = self.getLocalState();
        state.data = self.epoch;
    }
    
    pub fn online(self: *Self) void {
        const state = self.getLocalState();
        state.data = self.epoch;
        @fence(.SeqCst);
    }

    pub fn offline(self: *Self) void {
        @fence(.SeqCst);
        const state = self.getLocalState();
        state.data = 0;
    }
    
    pub fn barrier(self: *Self) EpochType {
        var epoch = self.epoch;
        while(true){
            var new_val:EpochType = undefined;
            if(epoch == std.math.maxInt(EpochType)){ // skip 0
                new_val = 1;
            } else {
                new_val = epoch + 1;
            }
            
            if(@cmpxchgWeak(EpochType, &self.epoch, epoch, new_val, .SeqCst, .Monotonic)) |v|{
                epoch = v;
                continue;
            }
            return new_val;
        }
    }
    
    pub fn sync(self: *Self, target: EpochType) bool {
        const lock = self.mutex.acquire();
        defer lock.release();
        self.quiescent();
        var p = self.queue.first;
        while(p) |ptr| :({p = ptr.next;}){     // traverse per-thread Nodes
            if(ptr.data == 0){
                continue;
            }
            if(ptr.data < target){
                return false;
            }
        }
        return true;
    }
    
};



const Param = struct {
    qsbr: *Qsbr,
    id: usize,
};


pub fn qsbr_test(param: Param) void {
    param.qsbr.register();
    defer param.qsbr.unregister();
    param.qsbr.quiescent();
    print("{}\n", .{param.qsbr.getLocalState()});
}


test "usage" {
    var qs = Qsbr.init(null);
    
    _ = qs.barrier();
    var param = Param{.qsbr=&qs, .id=0};
    var a:[10]*std.Thread = undefined;
    for(a) |*item|{
        item.* = std.Thread.spawn(param, qsbr_test) catch unreachable;
        param.id+=1;
    }
    for(a)|item, idx|{
        item.wait();
    }

    print("{*}\n", .{qs.getLocalState()});
    print("{}\n", .{&qs});
    print("{}\n", .{qs.sync(2)});
    return;
}


