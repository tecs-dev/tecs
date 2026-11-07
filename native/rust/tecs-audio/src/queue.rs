//! A bounded single-producer, single-consumer queue that neither side ever
//! waits on.
//!
//! This is what replaced the lock the output callback used to share with its
//! callers. The control side pushes prepared messages and the render side
//! pops them at the start of each render; the render side pushes what it
//! observed and what it finished with, and the control side pops those. A
//! push that finds no room fails and hands the value back, so the producer
//! decides what to do with it: the control side keeps it for the next call,
//! and the render side holds on to it.
//!
//! `head` is the next slot to read and `tail` the next to write, both counted
//! without wrapping, so full and empty are told apart by their distance. The
//! producer alone moves `tail` and the consumer alone moves `head`, which the
//! two halves enforce by taking `&mut self`.

use std::cell::UnsafeCell;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

struct Ring<T> {
    slots: Box<[UnsafeCell<MaybeUninit<T>>]>,
    head: AtomicUsize,
    tail: AtomicUsize,
}

// SAFETY: a slot is written only by the producer before it publishes `tail`
// and read only by the consumer after it observes it, so no slot is touched
// from two threads at once. `T: Send` is what lets the value cross.
unsafe impl<T: Send> Send for Ring<T> {}
unsafe impl<T: Send> Sync for Ring<T> {}

impl<T> Drop for Ring<T> {
    fn drop(&mut self) {
        let head = *self.head.get_mut();
        let tail = *self.tail.get_mut();
        let capacity = self.slots.len();
        for index in head..tail {
            // SAFETY: every slot from head to tail holds a value written and
            // not yet read, and nothing else can reach the ring now.
            unsafe { self.slots[index % capacity].get_mut().assume_init_drop() };
        }
    }
}

/// The writing half.
pub struct Producer<T> {
    ring: Arc<Ring<T>>,
}

/// The reading half.
pub struct Consumer<T> {
    ring: Arc<Ring<T>>,
}

/// Makes a queue holding up to `capacity` values, allocating it now.
pub fn queue<T: Send>(capacity: usize) -> (Producer<T>, Consumer<T>) {
    let capacity = capacity.max(1);
    let slots = (0..capacity)
        .map(|_| UnsafeCell::new(MaybeUninit::uninit()))
        .collect::<Vec<_>>()
        .into_boxed_slice();
    let ring = Arc::new(Ring {
        slots,
        head: AtomicUsize::new(0),
        tail: AtomicUsize::new(0),
    });
    (
        Producer {
            ring: Arc::clone(&ring),
        },
        Consumer { ring },
    )
}

impl<T> Producer<T> {
    /// Adds a value, or hands it back when the queue is full.
    pub fn push(&mut self, value: T) -> Result<(), T> {
        let ring = &*self.ring;
        let tail = ring.tail.load(Ordering::Relaxed);
        let head = ring.head.load(Ordering::Acquire);
        if tail - head == ring.slots.len() {
            return Err(value);
        }
        // SAFETY: the slot at `tail` is free, since the consumer has read up
        // to `head` and the producer alone writes; see `Ring`.
        unsafe { (*ring.slots[tail % ring.slots.len()].get()).write(value) };
        ring.tail.store(tail + 1, Ordering::Release);
        Ok(())
    }

    /// Reports how many more values fit.
    pub fn room(&self) -> usize {
        let ring = &*self.ring;
        ring.slots.len() - (ring.tail.load(Ordering::Relaxed) - ring.head.load(Ordering::Acquire))
    }
}

impl<T> Consumer<T> {
    /// Takes the oldest value, if there is one.
    pub fn pop(&mut self) -> Option<T> {
        let ring = &*self.ring;
        let head = ring.head.load(Ordering::Relaxed);
        let tail = ring.tail.load(Ordering::Acquire);
        if head == tail {
            return None;
        }
        // SAFETY: the slot at `head` was written before `tail` passed it,
        // and the consumer alone reads; see `Ring`.
        let value = unsafe { (*ring.slots[head % ring.slots.len()].get()).assume_init_read() };
        ring.head.store(head + 1, Ordering::Release);
        Some(value)
    }

    /// Reports how many values wait.
    pub fn len(&self) -> usize {
        let ring = &*self.ring;
        ring.tail.load(Ordering::Acquire) - ring.head.load(Ordering::Relaxed)
    }

    /// Reports whether nothing waits.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hands_values_across_threads_in_order_and_refuses_when_full() {
        let (mut producer, mut consumer) = queue::<Box<u64>>(4);
        for value in 0..4 {
            producer.push(Box::new(value)).unwrap();
        }
        assert!(producer.push(Box::new(9)).is_err(), "a fifth does not fit");
        assert_eq!(*consumer.pop().unwrap(), 0);
        producer.push(Box::new(4)).unwrap();
        let reader = std::thread::spawn(move || {
            let mut seen = Vec::new();
            while seen.len() < 4 {
                if let Some(value) = consumer.pop() {
                    seen.push(*value);
                }
            }
            seen
        });
        assert_eq!(reader.join().unwrap(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn drops_what_was_never_read() {
        let marker = Arc::new(());
        let (mut producer, consumer) = queue::<Arc<()>>(8);
        producer.push(Arc::clone(&marker)).unwrap();
        producer.push(Arc::clone(&marker)).unwrap();
        drop(producer);
        drop(consumer);
        assert_eq!(Arc::strong_count(&marker), 1);
    }
}
