#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define GETOBJ(obj) ((shared_sv*)SvIV(obj))
#define GETOBJRV(obj) ((shared_sv*)SvIV(SvRV(obj)))

PerlInterpreter *shared_sv_space;   /* use for shared variables */

void shared_sv_set (IV index, SV* obj);
SV* shared_sv_get (IV index, SV* obj);

typedef struct {
  SV* sv;
  perl_mutex lock;
  perl_cond  cond;
  I32 locks;
  SV* owner;
} shared_sv;

SV* init_shared_sv () {
	shared_sv* object = malloc(sizeof(shared_sv));
	SV* obj;
	obj = newSViv((IV)object);
	MUTEX_INIT(&object->lock);
	COND_INIT(&object->cond);
	object->locks = 0;
	return obj;
}


void shared_lock (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	if(object->owner && object->owner == SvRV(ref)) {
		object->locks++;
		return;
	}
	MUTEX_LOCK(&object->lock);
	if(object->locks != 0)
		printf("BAD ERROR\n");
	object->locks++;
	object->owner = SvRV(ref);
	return;
}

void shared_unlock (SV* ref) {
	shared_sv* object = GETOBJRV(ref);	
	if(object->owner != SvRV(ref)) {
		printf("you cannot unlock something you haven't got locked\n");
		return;
	}
	object->locks--;
	if(object->locks == 0) {
		object->owner = NULL;
		MUTEX_UNLOCK(&object->lock);
	}
	return;
}

void shared_thrcnt_inc (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter* old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	SvREFCNT_inc(object->sv);
/*	printf("threadcount is now %d\n",SvREFCNT(object->sv)); */
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

void shared_thrcnt_dec (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	shared_lock(ref);
	if(SvREFCNT(object->sv) == 1) {
	} else {
	 	SvREFCNT_dec(object->sv);
	}
/*	printf("threadcount is now %d\n",SvREFCNT(object->sv)); */
	shared_unlock(ref);
}



void shared_cond_wait (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	if(object->owner != SvRV(ref)) {
		printf("you are not the owner of the lock");
		return;
	}
	object->locks = 0; 
	object->owner = NULL;
	COND_WAIT(&object->cond, &object->lock);
	object->locks++;
	object->owner = SvRV(ref);
}

void shared_cond_signal (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	COND_SIGNAL(&object->cond);
}

void shared_cond_broadcast (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	COND_BROADCAST(&object->cond);
}


SV* shared_sv_new () {
	PerlInterpreter *old = PERL_GET_CONTEXT;
	SV* obj;
	shared_sv* object;
	PERL_SET_CONTEXT(shared_sv_space);
	{
		obj = init_shared_sv();
		object = GETOBJ(obj);
		object->sv = newSVsv((SV*) &PL_sv_undef);		
	}
	PERL_SET_CONTEXT(old);
	return obj;
}

SV* shared_sv_fetch (SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	shared_lock(ref);
	retval = newSVsv(object->sv);
	shared_unlock(ref);
	return retval;
}

void shared_sv_store (SV* ref, SV* value) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter* old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	sv_setsv(object->sv, value);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

SV* shared_av_new () {
	PerlInterpreter *old = PERL_GET_CONTEXT;
	SV* obj;
	shared_sv* object;
	PERL_SET_CONTEXT(shared_sv_space);
	{
		obj = init_shared_sv();
		object = GETOBJ(obj);
		object->sv = (SV*) newAV();
	}
	PERL_SET_CONTEXT(old);
	return obj;
}

void shared_av_store (SV* ref, SV* index, SV* value) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter* old = PERL_GET_CONTEXT;
	SV** av_entry_;
	SV* av_entry;
	
	PERL_SET_CONTEXT(shared_sv_space);	

/*
	if(SvROK(value)) {
		printf("this is a ref, we need to share it\n");
	} else {
	   	SV* scalar = shared_sv_new();				
		shared_sv* shared_object = GETOBJ(scalar);
		shared_object->sv  = newSVsv(value);
		value = scalar;
	}	
*/

	shared_lock(ref);
	av_entry_ = av_fetch((AV*) object->sv, (I32) SvIV(index),0);


	if(av_entry_) {
		av_entry = (*av_entry_);
	} else {
		av_entry = shared_sv_new();
		av_store((AV*) object->sv, (I32) SvIV(index),av_entry);
	}	
	sv_setsv(GETOBJ(av_entry)->sv, value);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

SV* shared_av_fetch(SV* ref, SV* index) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	SV** av_entry;
	shared_lock(ref);
	av_entry = av_fetch((AV*) object->sv, (I32) SvIV(index),0);	
	if(av_entry) {
		retval = newSVsv(GETOBJ((*av_entry))->sv);
	} else {
		retval = newSVsv((SV*) &PL_sv_undef);		
	}	
	shared_unlock(ref);
	return retval;
}

SV* shared_av_fetchsize(SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	shared_lock(ref);
	retval = newSViv(av_len((AV*)object->sv) + 1);
	shared_unlock(ref);
	return retval;
}

void shared_av_extend(SV* ref, SV* count) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	av_extend((AV*) object->sv, (I32) SvIV(count));
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

SV* shared_av_exists(SV* ref, SV* index) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	I32 exists;
	shared_lock(ref);
	exists = av_exists((AV*) object->sv, (I32) SvIV(index) );
	if(exists) {
		retval = newSViv(1);
	} else {
		retval = newSViv(0);
	}		
	shared_unlock(ref);
	return retval;
}

void shared_av_storesize(SV* ref, SV* count) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	av_fill((AV*) object->sv, (I32) SvIV(count));	
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

SV* shared_av_delete(SV* ref, SV* index) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	shared_lock(ref);

	if(av_exists((AV*) object->sv, (I32) SvIV(index))) {
		PerlInterpreter* old = PERL_GET_CONTEXT;
		SV* tmpvar;
		PERL_SET_CONTEXT(shared_sv_space);
		tmpvar = newRV_noinc(av_delete((AV*) object->sv, (I32) SvIV(index),0));
		PERL_SET_CONTEXT(old);
		retval = newSVsv(GETOBJRV(tmpvar)->sv);
		shared_thrcnt_dec(tmpvar);
	} else {
		retval = newSVsv((SV*) &PL_sv_undef);
	}	
	shared_unlock(ref);
	return retval;
}

void shared_av_clear(SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	SV **svp;
	I32 i;
	PerlInterpreter* old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);	
	shared_lock(ref);
	svp = AvARRAY((AV*)object->sv);
	i = AvFILLp((AV*)object->sv);
	while (i >= 0) {
		if(SvIV(svp[i])) {
			SV* tmp = newRV_noinc(svp[i]);
			shared_thrcnt_dec(tmp);
		}
		i--;
	}
	av_clear((AV*) object->sv);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

void shared_av_push(SV* ref, AV* param) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter* old = PERL_GET_CONTEXT;
	I32 i;
	SV **svp;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	svp = AvARRAY(param);
	i = AvFILLp(param);
	while (i >= 0) {
		SV* tmp = shared_sv_new();
		sv_setsv(GETOBJ(tmp)->sv, svp[i]);		
		av_push((AV*) object->sv, tmp);
		i--;
	}	
	shared_unlock(ref);	
	PERL_SET_CONTEXT(old);
}

void shared_av_unshift(SV* ref, AV* param) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter* old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	{
		SV **svp;
		I32 i = 0;	
		I32 len = av_len(param);
		len++;
		if(len) {
			av_unshift((AV*) object->sv,len);
			svp = AvARRAY(param);
		 	while(i < len) {
				SV* tmp = shared_sv_new();
				sv_setsv(GETOBJ(tmp)->sv,svp[i]);
				av_store((AV*) object->sv, i, tmp);
				i++;
			}	
		}
	}		
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

SV* shared_av_shift(SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	SV* tmp;
	shared_lock(ref);
	tmp = av_shift((AV*) object->sv);
	retval = newSVsv(GETOBJ(tmp)->sv);
	shared_thrcnt_dec(newRV_noinc(tmp));
	shared_unlock(ref);
	return retval;
}

SV* shared_av_pop(SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	SV* tmp;
	shared_lock(ref);
	tmp = av_pop((AV*) object->sv);
	retval = newSVsv(GETOBJ(tmp)->sv);
	shared_thrcnt_dec(newRV_noinc(tmp));
	shared_unlock(ref);
	return retval;
}

SV* shared_hv_new () {
	PerlInterpreter *old = PERL_GET_CONTEXT;
	SV* obj;
	shared_sv* object;
	PERL_SET_CONTEXT(shared_sv_space);
	{
		obj = init_shared_sv();
		object = GETOBJ(obj);
		object->sv = (SV*) newHV();
	}
	PERL_SET_CONTEXT(old);
	return obj;
}

void shared_hv_store (SV* ref, SV* key, SV* value) {
	SV** hv_entry_;
	SV* hv_entry;
	char* ckey;
	STRLEN len;

	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter *old = PERL_GET_CONTEXT;

	shared_lock(ref);


	ckey = SvPV(key, len);

	PERL_SET_CONTEXT(shared_sv_space);

	hv_entry_ = hv_fetch((HV*) object->sv, ckey,len,0);

	if(hv_entry_) {
		hv_entry = (*hv_entry_);
	} else {
		hv_entry = shared_sv_new();
		hv_store((HV*) object->sv, ckey, len, hv_entry,0);
	}
	sv_setsv(GETOBJ(hv_entry)->sv, value);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

SV* shared_hv_fetch (SV* ref, SV* key) {
	shared_sv* object = GETOBJRV(ref);
	char* ckey;
	STRLEN len;
	SV* retval;
	SV** hv_entry;
	shared_lock(ref);

	ckey = SvPV(key, len);

	hv_entry = hv_fetch((HV*) object->sv, ckey,len,0);

	if(hv_entry) {
		retval = newSVsv(GETOBJ((*hv_entry))->sv);
	} else {
		retval = newSVsv((SV*) &PL_sv_undef);		
	}	

	shared_unlock(ref);
	return retval;
}

SV* shared_hv_exists (SV* ref, SV* key) {
	shared_sv* object = GETOBJRV(ref);
	char* ckey;
	STRLEN len;
	SV* retval;
	bool truth;
	shared_lock(ref);
	ckey = SvPV(key, len);
	truth = hv_exists((HV*) object->sv, ckey, len);
	if(truth) {
		retval = newSViv(1);
	} else {
		retval = newSViv(0);
	}
	shared_unlock(ref);
	return retval;
}

SV* shared_hv_delete( SV* ref, SV* key) {
	shared_sv* object = GETOBJRV(ref);
	char* ckey;
	STRLEN len;
	SV* retval;
	SV* tmp;
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	ckey = SvPV(key, len);
	shared_lock(ref);
	tmp = hv_delete((HV*) object->sv, ckey, len,0);
	PERL_SET_CONTEXT(old);
	if(tmp) {
		retval = newSVsv(GETOBJ(tmp)->sv);
	} else {
		retval = newSVsv((SV*) &PL_sv_undef);		
	}	
	shared_unlock(ref);
	return retval;
}

SV* shared_hv_firstkey(SV* ref) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	HE* entry;
	char* key = NULL;
	I32 len;
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	hv_iterinit((HV*) object->sv);
	entry = hv_iternext((HV*) object->sv);

	if(entry) {	
		key = hv_iterkey(entry,&len);
	}
	PERL_SET_CONTEXT(old);
	if(entry) {
		retval = newSVpv(key, len);
	} else {
		retval = newSVsv((SV*) &PL_sv_undef);
	}
	shared_unlock(ref);
	return retval;
}

SV* shared_hv_nextkey(SV* ref, SV*key) {
	shared_sv* object = GETOBJRV(ref);
	SV* retval;
	HE* entry;
	char* ckey = NULL;
	I32 len;
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	entry = hv_iternext((HV*) object->sv);

	if(entry) {	
		ckey = hv_iterkey(entry,&len);
	}
	PERL_SET_CONTEXT(old);
	if(entry) {
		retval = newSVpv(ckey, len);
	} else {
		retval = newSVsv((SV*) &PL_sv_undef);
	}
	shared_unlock(ref);
	return retval;
}

void shared_hv_clear (SV *ref) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	hv_clear((HV*) object->sv);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

MODULE = threads::shared		PACKAGE = threads::shared		


PROTOTYPES: DISABLE


BOOT:
	{
		SV* temp = get_sv("threads::sharedsvspace", FALSE);
		shared_sv_space = (PerlInterpreter*) SvIV(temp);
	}

SV*
ptr(ref)
	SV* ref
	CODE:
	RETVAL = newSViv((I32)GETOBJRV(ref));
	OUTPUT:
	RETVAL

void
_lock(ref)
	SV* ref
	CODE:
	shared_lock(ref);
	XSRETURN_EMPTY;

void
_unlock(ref)
	SV* ref
	CODE:
	shared_unlock(ref);
	XSRETURN_EMPTY;

void
_cond_wait(ref)
	SV* ref
	CODE:
	shared_cond_wait(ref);
	XSRETURN_EMPTY;

void
_cond_signal(ref)
	SV* ref
	CODE:
	shared_cond_signal(ref);
	XSRETURN_EMPTY;

void
_cond_broadcast(ref)
	SV* ref
	CODE:
	shared_cond_broadcast(ref);
	XSRETURN_EMPTY;

void
thrcnt_inc(ref)
	SV* ref
	CODE:
	shared_thrcnt_inc(ref);
	XSRETURN_EMPTY;

void
thrcnt_dec(ref)
	SV* ref
	CODE:
	shared_thrcnt_dec(ref);
	XSRETURN_EMPTY;

MODULE = threads::shared		PACKAGE = threads::shared::sv		


SV*
FETCH(ref)
	SV* ref
	CODE:
	RETVAL = shared_sv_fetch(ref);
	OUTPUT:
	RETVAL


void
STORE(ref, value)
	SV* ref
	SV* value
	CODE:
	shared_sv_store(ref,value);
        XSRETURN_EMPTY;
       
	

SV*
new(class)
	char* class
	CODE:
	RETVAL = shared_sv_new();
	OUTPUT:
	RETVAL


MODULE = threads::shared		PACKAGE = threads::shared::av		

SV*
new(class)
	char* class
	CODE:
	RETVAL = shared_av_new();
	OUTPUT:
	RETVAL

void
STORE(ref, index, value)
	SV* ref
	SV* index
	SV* value
	CODE:
	shared_av_store(ref,index,value);
    XSRETURN_EMPTY;

void
STORESIZE(ref, count)
	SV* ref
	SV* count
	CODE:
	shared_av_storesize(ref,count);
    XSRETURN_EMPTY;


void
EXTEND(ref, count)
	SV* ref
	SV* count
	CODE:
	shared_av_extend(ref, count);
	XSRETURN_EMPTY;


SV* 
EXISTS(ref,index);
	SV* ref
	SV* index
	CODE:
	RETVAL = shared_av_exists(ref, index);
	OUTPUT:
	RETVAL

SV *
DELETE(ref, index);
	SV* ref
	SV* index
	CODE:
	RETVAL = shared_av_delete(ref, index);
	OUTPUT:
	RETVAL

void
CLEAR(ref)
	SV* ref
	CODE:
	shared_av_clear(ref);	
	XSRETURN_EMPTY;


SV*
FETCH(ref, index)
	SV* ref
	SV* index
	CODE:
	RETVAL = shared_av_fetch(ref,index);
	OUTPUT:
	RETVAL


SV*
FETCHSIZE(ref)
	SV* ref
	CODE:
	RETVAL = shared_av_fetchsize(ref);
	OUTPUT:
	RETVAL

void
PUSH(ref, ...)
	SV* ref;
	CODE:
	AV* params = newAV();
	if(items > 1) {
		int i;
		for(i = 1; i < items ; i++) {
			av_push(params, ST(i));
			}
		}
	shared_av_push(ref,params);
	XSRETURN_EMPTY;


void
UNSHIFT(ref, ...)
	SV* ref;
	CODE:
	AV* params = newAV();
	if(items > 1) {
		int i;
		for(i = 1; i < items ; i++) {
			av_push(params, ST(i));
			}
		}
	shared_av_unshift(ref,params);
	XSRETURN_EMPTY;


SV*
SHIFT(ref)
	SV* ref
	CODE:
	RETVAL = shared_av_shift(ref);
	OUTPUT:
	RETVAL

SV*
POP(ref)
	SV* ref
	CODE:
	RETVAL = shared_av_pop(ref);
	OUTPUT:
	RETVAL

void
SPLICE(ref, ...);
	SV* ref;
	CODE:
	printf("SPLICE IS NOT SUPPORTED\n");

MODULE = threads::shared		PACKAGE = threads::shared::hv		

SV*
new(class)
	char* class
	CODE:
	RETVAL = shared_hv_new();
	OUTPUT:
	RETVAL

void
STORE(ref, key, value)
	SV* ref
	SV* key
	SV* value
	CODE:
	shared_hv_store(ref, key, value);	
	XSRETURN_EMPTY;

SV*
FETCH(ref, key)
	SV* ref
	SV* key
	CODE:
	RETVAL = shared_hv_fetch(ref, key);
	OUTPUT:
	RETVAL

SV*
EXISTS(ref, key)
	SV* ref
	SV* key
	CODE:
	RETVAL = shared_hv_exists(ref, key);
	OUTPUT:
	RETVAL

SV*
DELETE(ref, key)
	SV* ref
	SV* key
	CODE:
	RETVAL = shared_hv_delete(ref, key);
	OUTPUT:
	RETVAL


void
CLEAR(ref)
	SV* ref
	CODE:
	shared_hv_clear(ref);
	XSRETURN_EMPTY;

SV*
FIRSTKEY(ref)
	SV* ref
	CODE:
	RETVAL = shared_hv_firstkey(ref);
	OUTPUT:
	RETVAL

SV*
NEXTKEY(ref, key)
	SV* ref
	SV* key
	CODE:
	RETVAL = shared_hv_nextkey(ref, key);
	OUTPUT:
	RETVAL

