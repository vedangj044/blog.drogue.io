
let menuLinks = document.querySelectorAll('.menu a');

// when clicking
menuLinks.forEach(link => {
    link.onclick = (()=> {
        setTimeout(()=> {
            menuLinks.forEach( el => el.classList.remove('is-active'))
            link.classList.add('is-active')
        },300)
    })
})

// when scrolling
window.onscroll = (()=> {
    let mainSection = document.querySelectorAll('h1, h2, h3, h4');

    let active = null;

    mainSection.forEach((el)=> {
        if (active) {
            return;
        }
        let id = el.id;
        if (!id) {
            return;
        }

        let rect = el.getBoundingClientRect();

        console.log(id, rect)

        if ( rect.top >= -5 ) {
            active = id;
        }

    })

    if (active) {
        menuLinks.forEach(el => el.classList.remove('is-active'))
        menuLinks
            .forEach(el => {
                if (el.getAttribute("data-for") === active ) {
                    el.classList.add('is-active')
                }
            } )
    }
})