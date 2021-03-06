# A Seq represents anything that can lazily produce a sequence of values. A
# Seq is born in a state where iterating it will consume the values. However,
# calling .cache on a Seq will return a List that will lazily reify to the
# values in the Seq. The List is memoized, so that subsequent calls to .cache
# will always return the same List (safe thanks to List being immutable). More
# than one call to .iterator throws an exception (and calling .cache calls the
# .iterator method the first time also). The memoization can be avoided by
# asking very specifically for the Seq to be coerced to a List (using .List or .list), a
# Slip (.Slip) or an Array (.Array). The actual memoization functionality is
# factored out into a role, PositionalBindFailover, which is used by the binder
# to identify types that, on failure to bind to an @-sigilled thing, can have
# .cache called on them and expect memoization semantics. This not only makes
# it easy for HyperSeq to also have this functionality, but makes it available
# for other kinds of paradigm that show up in the future (beyond sequential
# and parallel) that also want to have this behavior.
my $in_deprecation;
my class X::Seq::Consumed { ... }
my class X::Seq::NotIndexable { ... }
my role PositionalBindFailover {
    has $!list;

    method cache() {
        $!list.DEFINITE
            ?? $!list
            !! ($!list := List.from-iterator(self.iterator))
    }
    method list() {
            List.from-iterator(self.iterator)
    }

    method iterator() { ... }
}
nqp::p6configposbindfailover(Positional, PositionalBindFailover); # Binder
Routine.'!configure_positional_bind_failover'(Positional, PositionalBindFailover); # Multi-dispatch
my class Seq is Cool does Iterable does PositionalBindFailover {
    # The underlying iterator that iterating this sequence will work its
    # way through. Can only be obtained once.
    has Iterator $!iter;

    # The only valid way to create a Seq directly is by giving it the
    # iterator it will consume and maybe memoize.
    method new(Iterator:D $iter) {
        nqp::p6bindattrinvres(nqp::create(self),Seq,'$!iter',nqp::decont($iter))
    }

    method new-consumed() {
        self.bless;
    }

    method is-ready(Seq:D:) { $!iter.DEFINITE }

    method iterator(Seq:D:) {
        nqp::if(
          (my \iter = $!iter).DEFINITE,
          nqp::stmts(
            ($!iter := Iterator),
            iter
          ),
          X::Seq::Consumed.new.throw
        )
    }

    method is-lazy(Seq:D:) {
        nqp::if(
          $!iter.DEFINITE,
          $!iter.is-lazy,
          X::Seq::Consumed.new.throw
        )
    }

    method eager {
        List.from-iterator(self.iterator).eager;
    }

    method List() {
        List.from-iterator(self.iterator)
    }

    method Slip() {
        Slip.from-iterator(self.iterator)
    }

    method Array() {
        Array.from-iterator(self.iterator)
    }

    method elems() {
        nqp::if(
          self.is-lazy,
          Failure.new(X::Cannot::Lazy.new(action => '.elems')),
          nqp::if(
            ($!iter.DEFINITE && nqp::can($!iter,'count-only')),
            $!iter.count-only,
            self.cache.elems
          )
        )
    }

    method Numeric() {
        nqp::if(
          ($!iter.DEFINITE && nqp::can($!iter,'count-only')),
          $!iter.count-only,
          self.cache.Numeric
        )
    }

    method Int() {
        nqp::if(
          ($!iter.DEFINITE && nqp::can($!iter,'count-only')),
          $!iter.count-only,
          self.cache.Int
        )
    }

    method Bool(Seq:D:) {
        nqp::if(
          $!iter.DEFINITE,
          nqp::if(
            nqp::can($!iter,'bool-only'),
            $!iter.bool-only,
            nqp::if(
              nqp::can($!iter,'count-only'),
              ?$!iter.count-only,
              self.cache.Bool
            )
          ),
          self.cache.Bool
        )
    }

    multi method Str(Seq:D:) {
        self.cache.Str
    }

    multi method Stringy(Seq:D:) {
        self.cache.Stringy
    }

    method fmt(|c) {
        self.cache.fmt(|c)
    }

    multi method gist(Seq:D:) {
        self.cache.gist
    }

    multi method perl(Seq:D \SELF:) {
        unless $!iter.DEFINITE && ! $!list.DEFINITE {
            # cannot call .cache on a Seq that's already been iterated,
            # so we need to produce a string that, when EVAL'd, reproduces
            # an already iterated Seq.
            # compare RT #127492
            return self.^name ~ '.new-consumed()';
        }
        self.cache.perl ~ '.Seq';
    }

    method sink() {
        self.iterator.sink-all if $!iter.DEFINITE;
        Nil
    }

    multi method AT-POS(Seq:D: Int $idx) is raw {
        self.cache.AT-POS($idx)
    }

    multi method AT-POS(Seq:D: int $idx) is raw {
        self.cache.AT-POS($idx)
    }

    multi method EXISTS-POS(Seq:D: Int $idx) {
        self.cache.EXISTS-POS($idx)
    }

    multi method EXISTS-POS(Seq:D: int $idx) {
        self.cache.EXISTS-POS($idx)
    }

    multi method invert(Seq:D:) { self.list.invert }

    # Lazy loops produce a Seq wrapping a loop iterator. We have a few
    # special cases of that.
    my class InfiniteLoopIter does SlippyIterator {
        has &!body;

        method new(&body) {
            my \iter = nqp::create(self);
            nqp::bindattr(iter, self, '&!body', &body);
            iter
        }

        method pull-one() {
            my int $redo = 1;
            my $result;
            if $!slipping && !(($result := self.slip-one()) =:= IterationEnd) {
                $result
            }
            else {
                nqp::while(
                    $redo,
                    nqp::stmts(
                        $redo = 0,
                        nqp::handle(
                            nqp::stmts(
                                ($result := &!body()),
                                nqp::if(
                                    nqp::istype($result, Slip),
                                    nqp::stmts(
                                        ($result := self.start-slip($result)),
                                        nqp::if(
                                            nqp::eqaddr($result, IterationEnd),
                                            ($redo = 1)
                                        ))
                                    )),
                            'NEXT', ($redo = 1),
                            'REDO', ($redo = 1),
                            'LAST', ($result := IterationEnd))),
                    :nohandler);
                $result
            }
        }

        method is-lazy() { True }
    }

    my class WhileLoopIter does SlippyIterator {
        has &!body;
        has &!cond;
        has int $!skip-cond;

        method new(&body, &cond, :$repeat) {
            my \iter = nqp::create(self);
            nqp::bindattr(iter, self, '&!body', &body);
            nqp::bindattr(iter, self, '&!cond', &cond);
            nqp::bindattr_i(iter, self, '$!skip-cond', $repeat ?? 1 !! 0);
            iter
        }

        method pull-one() {
            my int $redo = 1;
            my $result;
            if $!slipping && !(($result := self.slip-one()) =:= IterationEnd) {
                $result
            }
            else {
                if $!skip-cond || &!cond() {
                    $!skip-cond = 0;
                    nqp::while(
                        $redo,
                        nqp::stmts(
                            $redo = 0,
                            nqp::handle(
                                nqp::stmts(
                                    ($result := &!body()),
                                    nqp::if(
                                        nqp::istype($result, Slip),
                                        nqp::stmts(
                                            ($result := self.start-slip($result)),
                                            nqp::if(
                                                nqp::eqaddr($result, IterationEnd),
                                                ($redo = &!cond() ?? 1 !! 0)
                                            ))
                                        )),
                                'NEXT', ($redo = &!cond() ?? 1 !! 0),
                                'REDO', ($redo = 1),
                                'LAST', ($result := IterationEnd))),
                        :nohandler);
                    $result
                }
                else {
                    IterationEnd
                }
            }
        }

        method is-lazy() { False }
    }

    my class CStyleLoopIter does SlippyIterator {
        has &!body;
        has &!cond;
        has &!afterwards;
        has int $!first-time;

        method new(&body, &cond, &afterwards) {
            my \iter = nqp::create(self);
            nqp::bindattr(iter, self, '&!body', &body);
            nqp::bindattr(iter, self, '&!cond', &cond);
            nqp::bindattr(iter, self, '&!afterwards', &afterwards);
            nqp::bindattr_i(iter, self, '$!first-time', 1);
            iter
        }

        method pull-one() {
            my int $redo = 1;
            my $result;
            if $!slipping && !(($result := self.slip-one()) =:= IterationEnd) {
                $result
            }
            else {
                $!first-time
                    ?? ($!first-time = 0)
                    !! &!afterwards();
                if &!cond() {
                    nqp::while(
                        $redo,
                        nqp::stmts(
                            $redo = 0,
                            nqp::handle(
                                nqp::stmts(
                                    ($result := &!body()),
                                    nqp::if(
                                        nqp::istype($result, Slip),
                                        nqp::stmts(
                                            ($result := self.start-slip($result)),
                                            nqp::if(
                                                nqp::eqaddr($result, IterationEnd),
                                                nqp::stmts(
                                                    &!afterwards(),
                                                    ($redo = &!cond() ?? 1 !! 0))
                                            ))
                                        )),
                                'NEXT', nqp::stmts(
                                    &!afterwards(),
                                    ($redo = &!cond() ?? 1 !! 0)),
                                'REDO', ($redo = 1),
                                'LAST', ($result := IterationEnd))),
                        :nohandler);
                    $result
                }
                else {
                    IterationEnd
                }
            }
        }

        method is-lazy() { False }
    }

    proto method from-loop(|) { * }
    multi method from-loop(&body) {
        Seq.new(InfiniteLoopIter.new(&body))
    }
    multi method from-loop(&body, &cond, :$repeat) {
        Seq.new(WhileLoopIter.new(&body, &cond, :$repeat))
    }
    multi method from-loop(&body, &cond, &afterwards) {
        Seq.new(CStyleLoopIter.new(&body, &cond, &afterwards))
    }
}

sub GATHER(&block) {
    Seq.new(class :: does SlippyIterator {
        has &!resumption;
        has $!push-target;
        has int $!wanted;

        my constant PROMPT = nqp::create(Mu);

        method new(&block) {
            my \iter = nqp::create(self);
            my int $wanted;
            my $taken;
            my $taker := {
                nqp::stmts(
                  ($taken := nqp::getpayload(nqp::exception())),
                  nqp::if(
                    nqp::istype($taken, Slip),
                    nqp::stmts(
                      iter!start-slip-wanted($taken),
                      ($wanted = nqp::getattr_i(iter, self, '$!wanted'))
                    ),
                    nqp::stmts(  # doesn't sink
                      nqp::getattr(iter, self, '$!push-target').push($taken),
                      ($wanted = nqp::bindattr_i(iter,self,'$!wanted',
                        nqp::sub_i(nqp::getattr_i(iter,self,'$!wanted'),1)))
                    )
                  ),
                  nqp::if(
                    nqp::iseq_i($wanted,0),
                    nqp::continuationcontrol(0, PROMPT, -> Mu \c {
                        nqp::bindattr(iter, self, '&!resumption', c);
                    })
                  ),
                  nqp::resume(nqp::exception())
                )
            }
            nqp::bindattr(iter, self, '&!resumption', {
                nqp::stmts(  # doesn't sink
                  nqp::handle(&block(), 'TAKE', $taker()),
                  nqp::continuationcontrol(0, PROMPT, -> | {
                      nqp::bindattr(iter, self, '&!resumption', Callable)
                  })
                )
            });
            iter
        }

        method pull-one() is raw {
            nqp::if(
              $!slipping && nqp::not_i(
                nqp::eqaddr((my \result = self.slip-one),IterationEnd)
              ),
              result,
              nqp::stmts(
                nqp::unless(
                  $!push-target.DEFINITE,
                  ($!push-target := nqp::create(IterationBuffer))
                ),
                ($!wanted = 1),
                nqp::continuationreset(PROMPT, &!resumption),
                nqp::if(
                  &!resumption.DEFINITE,
                  nqp::shift($!push-target),
                  IterationEnd
                )
              )
            )
        }

        method push-exactly($target, int $n) {
            nqp::if(
              nqp::isgt_i($n,0),
              nqp::stmts(
                ($!wanted = $n),
                ($!push-target := $target),
                nqp::if(
                  $!slipping && nqp::not_i(
                    nqp::eqaddr(self!slip-wanted,IterationEnd)
                  ),
                  nqp::stmts(
                    ($!push-target := Mu),
                    $n
                  ),
                  nqp::stmts(
                    nqp::continuationreset(PROMPT, &!resumption),
                    ($!push-target := Mu),
                    nqp::if(
                      &!resumption.DEFINITE,
                      ($n - $!wanted),
                      IterationEnd
                    )
                  )
                )
              )
            )
        }

        method !start-slip-wanted(\slip --> Nil) {
            my $value := self.start-slip(slip);
            nqp::unless(
              nqp::eqaddr($value,IterationEnd),
              nqp::stmts(  # doesn't sink
                $!push-target.push($value),
                (my int $i = 0),
                (my int $n = $!wanted),
                nqp::while(  # doesn't sink
                  nqp::islt_i($i = nqp::add_i($i,1),$n),
                  nqp::if(
                    nqp::eqaddr(($value := self.slip-one),IterationEnd),
                    last
                  ),
                  $!push-target.push($value)
                ),
                ($!wanted = $!wanted - $i)
              )
            )
        }

        method !slip-wanted() {
            my int $i = -1;
            my int $n = $!wanted;
            my $value;
            nqp::while(
              nqp::islt_i($i = nqp::add_i($i,1),$n),
              nqp::stmts(  # doesn't sink
                nqp::if(
                  nqp::eqaddr(($value := self.slip-one),IterationEnd),
                  last
                ),
                $!push-target.push($value)
              )
            );
            $!wanted = nqp::sub_i($!wanted,$i);
            nqp::if(
              nqp::eqaddr($value,IterationEnd),
              IterationEnd,
              $n
            )
        }
    }.new(&block))
}

multi sub infix:<eqv>(Seq:D \a, Seq:D \b) {

    # we're us
    return True  if a =:= b;

    # not same container type
    return False unless a.WHAT =:= b.WHAT;

    my \ia := a.iterator;
    my \ib := b.iterator;
    my $va;
    my $vb;

    # same until a-list exhausted
    return False
      if    ($vb := ib.pull-one) =:= IterationEnd || !($va eqv $vb)
      until ($va := ia.pull-one) =:= IterationEnd;

    # b-list also exhausted?
    ib.pull-one =:= IterationEnd
}

# vim: ft=perl6 expandtab sw=4
