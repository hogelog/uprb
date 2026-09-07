#include "ruby.h"

extern int uprb_companion_value(void);

static VALUE fixture_value(VALUE self)
{
    return INT2NUM(uprb_companion_value());
}

void Init_uprb_fixture(void)
{
    VALUE fixture = rb_define_module("UprbFixture");
    rb_define_singleton_method(fixture, "value", fixture_value, 0);
}
