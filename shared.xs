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
//	printf("Trying to get lock for %d\n",object);
	if(object->owner && object->owner == SvRV(ref)) {
		object->locks++;
//		printf("Incrementing lock count for %d\n", object);
		return;
	}
//	printf("Mutex %d\n",&object->lock);
	MUTEX_LOCK(&object->lock);
//	printf("Got lock\n");
	if(object->locks != 0)
		printf("BAD ERROR\n");
	object->locks++;
	object->owner = SvRV(ref);
//	printf("Got the lock on %d\n",object);
	return;
}

void shared_unlock (SV* ref) {
	shared_sv* object = GETOBJRV(ref);	
	if(object->owner != SvRV(ref)) {
		printf("you cannot unlock something you haven't got locked\n");
		return;
	}
	object->locks--;
//	printf("Decremented lock count for %d\n",object);
	if(object->locks == 0) {
		object->owner = NULL;
//		printf("Release lock for %d\n",object);
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
//	printf("threadcount is now up to %d for %d\n",SvREFCNT(object->sv), object);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
}

void shared_thrcnt_dec (SV* ref) {
	PerlInterpreter* old = PERL_GET_CONTEXT;
	shared_sv* object = GETOBJRV(ref);
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);
	if(SvREFCNT(object->sv) == 1) {
//		printf("Killing object %d\n",object);
		switch (SvTYPE((SV*)object->sv)) {
			case SVt_PVMG:
			case SVt_RV:
				if(SvROK(object->sv)) {
					shared_thrcnt_dec(object->sv);
				}
			break;
	   	case SVt_PVAV:
			{
				SV **src_ary;
				SSize_t items = AvFILLp((AV*)object->sv) + 1;
				src_ary = AvARRAY((AV*)object->sv);
				while (items-- > 0) {
					if(SvTYPE(*src_ary)) {
						shared_thrcnt_dec(sv_2mortal(newRV(*src_ary++)));
					}
				}
			}		
			break;
		case SVt_PVHV:
			{
				HE* entry;
				entry = hv_iternext((HV*)object->sv);
				while(entry)	{
					shared_thrcnt_dec(sv_2mortal(newRV(hv_iterval((HV*) object->sv, entry))));			
					entry = hv_iternext((HV*)object->sv);
				}

			}
			break;
		};
		SvREFCNT_dec(object->sv);
		shared_unlock(ref);
		PERL_SET_CONTEXT(old);
		return;
	} else {
	 	SvREFCNT_dec(object->sv);
	}
//	printf("threadcount is now down to %d for %d\n",SvREFCNT(object->sv), object);
	shared_unlock(ref);
	PERL_SET_CONTEXT(old);
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

SV*  shared_find_object(SV* ref) {
	/* Here we tried if we are trying to assing a shared value */
	MAGIC *mg;
	SV* sv;
	if(!SvROK(ref)) {
		return ref;
	}


	sv = SvRV(ref);	
	/* this is a reference !*/
	if((mg = SvTIED_mg(sv, PERL_MAGIC_tied))) {
		SV* obj = SvTIED_obj(sv, mg);
		SV* objcopy = newSViv(SvIV(SvRV(obj)));
		ref = newRV_noinc(objcopy);


		return ref;		
	} else {
		/* here we should probably autoconvert to shared structure */
		croak("You cannot assign a non shared reference to a shared array or hash");
	}

}

SV* shared_attach_object(SV* retval) {
	shared_sv* object;
	HV* shared;
	SV* id;
	SV* tiedobject;
	STRLEN length;
	SV** tiedobject_ = 0;
	SV* obj = 0;


	if(!SvROK(retval)) {
		return retval;
	}
	object = GETOBJRV(retval);
	shared = get_hv("threads::shared::shared", FALSE);
	id = newSViv((IV)object);
	length = sv_len(id);
	tiedobject_ = hv_fetch(shared, SvPV(id,length), length, 0);
	if(tiedobject_) {
		tiedobject = (*tiedobject_);
		tiedobject = newRV_inc(SvRV(tiedobject));
	} else {
		//printf("Not found, we need to make a new object\n");
		tiedobject = newSV(0);
	}
	switch(SvTYPE(object->sv)) {
		case SVt_PVAV:
		if(SvTYPE(tiedobject) == SVt_NULL) {
			SV* weakref;
			obj = newSVrv(tiedobject, "threads::shared::av");
			sv_setiv(obj,(IV)object);
			weakref = newRV(obj);
			sv_rvweaken(weakref);
			hv_store(shared, SvPV(id,length), length, weakref, 0);
			shared_thrcnt_inc(tiedobject);
		}
		{
			AV* array = newAV();
			sv_magic((SV*)array,tiedobject,PERL_MAGIC_tied,Nullch,0);
			SvREFCNT_dec(tiedobject);
			retval = newRV_noinc((SV*)array);


		}
		break;
		case SVt_PVHV:
		if(SvTYPE(tiedobject) == SVt_NULL) {
			SV* weakref;
			obj = newSVrv(tiedobject, "threads::shared::hv");
			sv_setiv(obj,(IV)object);
			weakref = newRV(obj);
			sv_rvweaken(weakref);
			hv_store(shared, SvPV(id,length), length, weakref, 0);
			shared_thrcnt_inc(tiedobject);
		}
		{
			HV* hash = newHV();
			sv_magic((SV*)hash,tiedobject,PERL_MAGIC_tied,Nullch,0);
			SvREFCNT_dec(tiedobject);
			retval = newRV_noinc((SV*)hash);


		}
		break;
		default:

	};		

	return retval;
}



SV* shared_sv_new () {
	PerlInterpreter *old = PERL_GET_CONTEXT;
	SV* obj;
	shared_sv* object;


	obj = init_shared_sv();
	object = GETOBJ(obj);
	PERL_SET_CONTEXT(shared_sv_space);
	object->sv = newSVsv((SV*) &PL_sv_undef);		
	PERL_SET_CONTEXT(old);
	return obj;
}





I32 shared_sv_fetch (pTHX_ IV ref, SV* sv) {
	shared_sv* object = (shared_sv*) ref;
	SV* fakeref = newRV(newSViv((IV)object));
	SV* tmp;
	shared_lock(fakeref);
	tmp = sv_2mortal(newSVsv(object->sv));
	tmp = shared_attach_object(tmp);
	sv_setsv(sv,tmp);
	shared_unlock(fakeref);
	SvREFCNT_dec(fakeref);
	return 0;
}

I32 shared_sv_store (pTHX_ IV ref, SV* sv) {
	shared_sv* object = (shared_sv*) ref;
	SV* fakeref = newRV(newSViv((IV)object));
	PerlInterpreter* old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	
	sv = shared_find_object(sv);

	shared_lock(fakeref);
	if(SvROK(object->sv)) {
		shared_thrcnt_dec(object->sv);
	}	

	sv_setsv(object->sv, sv);
	if(SvROK(sv)) {
		shared_thrcnt_inc(sv);
	}
	shared_unlock(fakeref);
	PERL_SET_CONTEXT(old);
	SvREFCNT_dec(fakeref);
	return 0;
}

void shared_sv_attach(SV* ref, SV* sv) {
	shared_sv* object = GETOBJRV(ref);
        struct ufuncs uf;
        uf.uf_val = &shared_sv_fetch;
 	uf.uf_set = &shared_sv_store;
  	uf.uf_index = (IV) object; 

	sv_magic(sv, 0, PERL_MAGIC_uvar, (char*)&uf, sizeof(uf));
	SvREFCNT_inc(SvRV(ref)); 	
}

SV* shared_av_new () {
	PerlInterpreter *old = PERL_GET_CONTEXT;
	SV* obj;
	shared_sv* object;
	obj = init_shared_sv();
	object = GETOBJ(obj);
	PERL_SET_CONTEXT(shared_sv_space);
	object->sv = (SV*) newAV();
	PERL_SET_CONTEXT(old);
	return obj;
}



void shared_av_store (SV* ref, SV* index, SV* value) {
	shared_sv* object = GETOBJRV(ref);
	PerlInterpreter* old = PERL_GET_CONTEXT;
	SV** av_entry_;
	SV* av_entry;



	PERL_SET_CONTEXT(shared_sv_space);	

	value = shared_find_object(value);

	shared_lock(ref);
	av_entry_ = av_fetch((AV*) object->sv, (I32) SvIV(index),0);


	if(av_entry_) {
		av_entry = (*av_entry_);
		if(SvROK(GETOBJ(av_entry)->sv)) {
			shared_thrcnt_dec(GETOBJ(av_entry)->sv);
		}
	} else {
		av_entry = shared_sv_new();
		av_store((AV*) object->sv, (I32) SvIV(index),av_entry);
	}	
	if(SvROK(value)) {
		shared_thrcnt_inc(value);
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

	retval = shared_attach_object(retval);

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
		SV* value = shared_find_object(svp[i]);
		if(SvROK(value)) {
		 	shared_thrcnt_inc(value);
		}
		sv_setsv(GETOBJ(tmp)->sv, value);		
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
				SV* value = shared_find_object(svp[i]);
				if(SvROK(value)) {
		 			shared_thrcnt_inc(value);
				}
				sv_setsv(GETOBJ(tmp)->sv,value);
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
	retval = shared_attach_object(retval);
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
	retval = shared_attach_object(retval);
	shared_thrcnt_dec(newRV_noinc(tmp));
	shared_unlock(ref);
	return retval;
}

SV* shared_hv_new () {
	PerlInterpreter *old = PERL_GET_CONTEXT;
	SV* obj;
	shared_sv* object;



	obj = init_shared_sv();
	object = GETOBJ(obj);
	PERL_SET_CONTEXT(shared_sv_space);
	object->sv = (SV*) newHV();
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


	value = shared_find_object(value);


	hv_entry_ = hv_fetch((HV*) object->sv, ckey,len,0);

	if(hv_entry_) {
		hv_entry = (*hv_entry_);
		if(SvROK(GETOBJ(hv_entry)->sv)) {
			shared_thrcnt_dec(GETOBJ(hv_entry)->sv);
		}
	} else {
		hv_entry = shared_sv_new();
		hv_store((HV*) object->sv, ckey, len, hv_entry,0);
	}
	if(SvROK(value)) {
		shared_thrcnt_inc(value);
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
	retval = shared_attach_object(retval);

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
		retval = shared_attach_object(retval);
		shared_thrcnt_dec(sv_2mortal(newRV_noinc(tmp)));
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
	HE* entry;
	PerlInterpreter *old = PERL_GET_CONTEXT;
	PERL_SET_CONTEXT(shared_sv_space);
	shared_lock(ref);


	entry = hv_iternext((HV*)object->sv);
	while(entry)	{
		shared_thrcnt_dec(sv_2mortal(newRV(hv_iterval((HV*) object->sv, entry))));			
		entry = hv_iternext((HV*)object->sv);
	}
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
new(..)
	CODE:
	RETVAL = shared_sv_new();
	OUTPUT:
	RETVAL

void
attach(obj, sv)
	SV* obj
	SV* sv
	CODE:
	shared_sv_attach(obj, sv);

MODULE = threads::shared		PACKAGE = threads::shared::av		

SV*
new(..)
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
SPLICE(..);
	CODE:
	printf("SPLICE IS NOT SUPPORTED SHARED ARRAYS\n");

MODULE = threads::shared		PACKAGE = threads::shared::hv		

SV*
new(..)
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

